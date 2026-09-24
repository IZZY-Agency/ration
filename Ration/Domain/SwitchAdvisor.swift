import Foundation

/// "Switch to this account next": the in-use account of a provider is running
/// out and a same-provider account has clearly more room.
struct SwitchAdvice: Equatable, Sendable {
    let provider: Provider          // .claude or .chatGPT
    let fromAccountID: UUID         // the in-use account that's running out
    let fromLabel: String
    let toAccountID: UUID
    let toLabel: String
    let toHeadroom: Double          // 0…1, remaining on the target's binding limit
    let toBinding: UsageWindowKind  // which limit that headroom is measured on
}

/// Pure "which account next" advice rule.
///
/// - Only Claude and ChatGPT are advised; Cursor bills in dollars. Paused
///   accounts are never `from` nor a target.
/// - Every window is judged with `UsageEvidence.isCurrent` against its own
///   reset: a window overtaken by its reset (or a snapshot too old) is
///   unknown. Unknown windows can't trigger; an account with any unknown
///   considered window is not a target.
/// - Considered windows: 5h and weekly, plus Fable (`.modelWeekly`) when Fable
///   counts for the `from` account — then for targets too, regardless of
///   their own usage, so an exhausted-Fable account is never suggested to a
///   Fable user.
/// - `from` = among the provider's `.inUse` accounts that have crossed a
///   Warn (ANY known considered window at its own Warn threshold), the one
///   with the least binding headroom — so whoever just got the Warn
///   notification gets the advice. An
///   in-use account whose windows are all unknown can't be `from`.
/// - Target (plan tiers): remaining capacity = binding headroom × plan
///   units; a target needs ≥ `from` remaining + `requiredMargin` × the smaller
///   of the two plans' units (identical to the percentage rule for equal
///   plans). Unknown-plan accounts are only compared with each other.
///   Ties → capacity desc, soonest weekly reset (nil last), presentation order.
enum SwitchAdvisor {
    static let requiredMargin: Double = 0.20
    static let advisedProviders: [Provider] = [.claude, .chatGPT]

    /// Floating-point slack for "exactly 20 points more" (0.40 − 0.20 is not
    /// exactly 0.20 in binary).
    private static let marginTolerance: Double = 1e-9

    static func advice(
        presentations: [AccountPresentation],
        phases: [UUID: InUsePhase],
        thresholds: (Provider, UsageWindowKind) -> ThresholdPair,
        fableCounts: (UUID) -> Bool,
        now: Date
    ) -> [SwitchAdvice] {
        var result: [SwitchAdvice] = []
        for provider in advisedProviders {
            let pool: [AccountPresentation] = presentations.filter { presentation in
                presentation.account.provider == provider && !presentation.account.isPaused
            }
            let found: SwitchAdvice? = advice(
                provider: provider,
                pool: pool,
                phases: phases,
                thresholds: thresholds,
                fableCounts: fableCounts,
                now: now
            )
            if let found {
                result.append(found)
            }
        }
        return result
    }

    // MARK: - Per provider

    private static func advice(
        provider: Provider,
        pool: [AccountPresentation],
        phases: [UUID: InUsePhase],
        thresholds: (Provider, UsageWindowKind) -> ThresholdPair,
        fableCounts: (UUID) -> Bool,
        now: Date
    ) -> SwitchAdvice? {
        guard let from = fromCandidate(
            provider: provider,
            pool: pool,
            phases: phases,
            thresholds: thresholds,
            fableCounts: fableCounts,
            now: now
        ) else { return nil }

        let kinds: [UsageWindowKind] = UsageHeadroom.consideredKinds(includeFable: from.includesFable)
        let fromUnits: Double? = from.presentation.account.effectivePlan?.capacityUnits
        var targets: [Target] = []
        for (order, presentation) in pool.enumerated() {
            guard presentation.id != from.presentation.id else { continue }
            // Accounts with a problem the user must resolve first are never suggested.
            guard UsageHeadroom.isUsableState(presentation.state) else { continue }
            guard let snapshot = presentation.snapshot else { continue }
            let standing: Standing = UsageHeadroom.assess(snapshot, kinds: kinds, now: now)
            guard !standing.hasUnknown, let binding = standing.binding else { continue }
            // An unknown plan can't be sized against a known one. A `from`
            // with a plan compares only planned targets (by capacity); a
            // `from` without one compares only unplanned targets (by percent).
            let targetUnits: Double? = presentation.account.effectivePlan?.capacityUnits
            guard (fromUnits == nil) == (targetUnits == nil) else { continue }
            let fromScale: Double = fromUnits ?? 1
            let targetScale: Double = targetUnits ?? 1
            let fromRemaining: Double = from.binding.headroom * fromScale
            let targetRemaining: Double = binding.headroom * targetScale
            let margin: Double = requiredMargin * min(fromScale, targetScale)
            let gain: Double = targetRemaining - fromRemaining
            let tolerance: Double = marginTolerance * max(fromScale, targetScale)
            guard gain >= margin - tolerance else { continue }
            targets.append(Target(order: order, presentation: presentation, standing: standing, capacity: targetRemaining))
        }

        let sorted = targets.sorted { lhs, rhs in
            precedes(lhs: lhs, rhs: rhs)
        }
        guard let best = sorted.first, let bestBinding = best.standing.binding else { return nil }
        return SwitchAdvice(
            provider: provider,
            fromAccountID: from.presentation.id,
            fromLabel: from.presentation.account.label,
            toAccountID: best.presentation.id,
            toLabel: best.presentation.account.label,
            toHeadroom: bestBinding.headroom,
            toBinding: bestBinding.kind
        )
    }

    private struct FromCandidate {
        let presentation: AccountPresentation
        let standing: Standing
        let binding: Binding
        let includesFable: Bool
    }

    /// The least-headroom `.inUse` account among those that crossed a Warn on
    /// a known window (presentation order breaks ties).
    private static func fromCandidate(
        provider: Provider,
        pool: [AccountPresentation],
        phases: [UUID: InUsePhase],
        thresholds: (Provider, UsageWindowKind) -> ThresholdPair,
        fableCounts: (UUID) -> Bool,
        now: Date
    ) -> FromCandidate? {
        var best: FromCandidate?
        for presentation in pool {
            guard case .inUse = phases[presentation.id] else { continue }
            guard let snapshot = presentation.snapshot else { continue }
            let includesFable: Bool = fableCounts(presentation.id)
            let kinds: [UsageWindowKind] = UsageHeadroom.consideredKinds(includeFable: includesFable)
            let standing: Standing = UsageHeadroom.assess(snapshot, kinds: kinds, now: now)
            guard let binding = standing.binding else { continue }
            guard hasCrossedWarn(standing, provider: provider, thresholds: thresholds) else { continue }
            if let current = best, current.binding.headroom <= binding.headroom { continue }
            best = FromCandidate(
                presentation: presentation,
                standing: standing,
                binding: binding,
                includesFable: includesFable
            )
        }
        return best
    }

    private static func hasCrossedWarn(
        _ standing: Standing,
        provider: Provider,
        thresholds: (Provider, UsageWindowKind) -> ThresholdPair
    ) -> Bool {
        for entry in standing.known {
            let pair: ThresholdPair = thresholds(provider, entry.kind)
            if AlertTier.forUsed(entry.window.usedFraction, thresholds: pair) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - Targets

    private typealias Binding = UsageHeadroom.Binding
    private typealias Standing = UsageHeadroom.Standing

    private struct Target {
        let order: Int
        let presentation: AccountPresentation
        let standing: Standing
        /// Remaining capacity: binding headroom × plan units (1 when no plan).
        let capacity: Double
    }

    /// Capacity within `marginTolerance` counts as equal. The weekly-reset
    /// tie-break is best effort: Claude's `resetsAt` drifts slightly between
    /// polls, so two otherwise tied targets can swap order across refreshes.
    private static func precedes(lhs: Target, rhs: Target) -> Bool {
        let capacityGap: Double = abs(lhs.capacity - rhs.capacity)
        if capacityGap > marginTolerance {
            return lhs.capacity > rhs.capacity
        }
        let lhsReset: Date? = lhs.presentation.snapshot?.weekly?.resetsAt
        let rhsReset: Date? = rhs.presentation.snapshot?.weekly?.resetsAt
        switch (lhsReset, rhsReset) {
        case let (l?, r?) where l != r:
            return l < r
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.order < rhs.order
        }
    }
}
