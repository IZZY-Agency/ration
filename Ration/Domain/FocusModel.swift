import Foundation

/// The popover's Focus layout, top to bottom: one hero account as a big number,
/// a line per other account in use, a red line per nearly-spent account, a line
/// per switch advice, then a quiet wrapped row of everything else. Pure:
/// phases, advice, thresholds and the Fable verdict come in from `AppModel`,
/// headroom is judged by `UsageHeadroom` exactly as `SwitchAdvisor` judges it.
struct FocusModel: Equatable {
    enum EmptyState: Equatable {
        /// There is something to show (possibly only the list).
        case none
        /// No accounts at all → the existing "No accounts connected" state.
        case noAccounts
        /// Accounts exist but every one is paused → a note plus the list.
        case allPaused
    }

    /// What an account's line or entry says after its name.
    enum Value: Equatable {
        /// Remaining share of the binding limit, and which limit that is.
        case headroom(Double, UsageWindowKind)
        /// Cursor's spend this cycle.
        case spent(cents: Int)
        case paused
        /// A state the user may need to act on — drawn with the existing
        /// badge text (and the Sign In button for re-authentication).
        case state(AccountViewState)
        /// Nothing current to say (no snapshot yet, or its windows were
        /// overtaken by their resets).
        case noData
    }

    struct Limit: Equatable {
        let kind: UsageWindowKind
        let label: String?
        let headroom: Double
    }

    struct Hero: Equatable {
        /// The small tag after the name: the account's activity phase.
        enum Tag: Equatable {
            case inUse
            case lastUsed
            case none
        }

        let presentation: AccountPresentation
        let headroom: Double
        let bindingKind: UsageWindowKind
        /// The binding window's own name (only `.modelWeekly` has one).
        let bindingLabel: String?
        let tag: Tag
        /// The user picked this account from the list (until the surface
        /// closes); drawn with a way back to the automatic hero.
        let isPinned: Bool
        let resetsAt: Date?
        /// Every other window the snapshot reports whose evidence is current.
        let otherLimits: [Limit]

        var account: AccountRecord { presentation.account }
        var usedFraction: Double { 1 - headroom }
        /// Drawn as the IN USE tag — only for the bright `.inUse` phase.
        var isInUse: Bool { tag == .inUse }
    }

    struct Line: Equatable {
        let presentation: AccountPresentation
        let value: Value
        /// The binding window's reset (for a `.headroom` value).
        let resetsAt: Date?
        /// Eligible to be shown as the hero when clicked.
        let canBeHero: Bool

        var account: AccountRecord { presentation.account }
    }

    /// A nearly-spent account: some considered window's used share is at or
    /// past that window's Crit threshold. Names the crossed window with the
    /// least headroom.
    struct Warning: Equatable {
        let presentation: AccountPresentation
        let headroom: Double
        let kind: UsageWindowKind
        let label: String?
        let resetsAt: Date?

        var account: AccountRecord { presentation.account }
    }

    struct Entry: Equatable {
        let presentation: AccountPresentation
        let value: Value
        /// Eligible to be shown as the hero when clicked.
        let canBeHero: Bool

        var account: AccountRecord { presentation.account }
        var isDimmed: Bool { value == .paused }
    }

    let hero: Hero?
    let otherInUse: [Line]
    let warnings: [Warning]
    let switchLines: [SwitchAdvice]
    let others: [Entry]
    let emptyState: EmptyState

    /// Providers measured in percent — Cursor bills in dollars and is never a hero.
    static let percentProviders: Set<Provider> = [.claude, .chatGPT]

    static func make(
        presentations: [AccountPresentation],
        phases: [UUID: InUsePhase],
        advice: [SwitchAdvice],
        fableCounts: (UUID) -> Bool,
        thresholds: (Provider, UsageWindowKind) -> ThresholdPair = { _, _ in .default },
        pinnedHeroID: UUID? = nil,
        now: Date
    ) -> FocusModel {
        let emptyState: EmptyState
        if presentations.isEmpty {
            emptyState = .noAccounts
        } else if presentations.allSatisfy({ $0.account.isPaused }) {
            emptyState = .allPaused
        } else {
            emptyState = .none
        }

        let candidates: [Candidate] = heroCandidates(
            presentations: presentations,
            phases: phases,
            fableCounts: fableCounts,
            now: now
        )
        let eligible: Set<UUID> = Set(candidates.map(\.presentation.id))
        let hero: Hero? = pickHero(candidates: candidates, pinnedHeroID: pinnedHeroID, now: now)

        var shown: Set<UUID> = []
        if let hero {
            shown.insert(hero.presentation.id)
        }

        var otherInUse: [Line] = []
        for presentation in presentations {
            guard !presentation.account.isPaused else { continue }
            guard !shown.contains(presentation.id) else { continue }
            guard case .inUse = phases[presentation.id] else { continue }
            let value: Value = Self.value(for: presentation, fableCounts: fableCounts, now: now)
            var resetsAt: Date?
            if case let .headroom(_, kind) = value {
                resetsAt = presentation.snapshot?.window(for: kind)?.resetsAt
            }
            otherInUse.append(Line(
                presentation: presentation,
                value: value,
                resetsAt: resetsAt,
                canBeHero: eligible.contains(presentation.id)
            ))
            shown.insert(presentation.id)
        }

        var warnings: [Warning] = []
        for candidate in candidates where !shown.contains(candidate.presentation.id) {
            guard let warning = Self.warning(for: candidate, thresholds: thresholds) else { continue }
            warnings.append(warning)
            shown.insert(candidate.presentation.id)
        }

        for item in advice {
            shown.insert(item.toAccountID)
        }

        var others: [Entry] = []
        for provider in Provider.allCases {
            for presentation in presentations where presentation.account.provider == provider {
                // Paused accounts are hidden in Focus, as in Standard; with
                // every account paused only the note shows.
                guard !presentation.account.isPaused else { continue }
                guard !shown.contains(presentation.id) else { continue }
                let value: Value = Self.value(for: presentation, fableCounts: fableCounts, now: now)
                others.append(Entry(
                    presentation: presentation,
                    value: value,
                    canBeHero: eligible.contains(presentation.id)
                ))
            }
        }

        return FocusModel(
            hero: hero,
            otherInUse: otherInUse,
            warnings: warnings,
            // A line whose target IS the hero (e.g. pinned by clicking that
            // line) would only repeat what the hero already shows.
            switchLines: advice.filter { $0.toAccountID != hero?.presentation.id },
            others: others,
            emptyState: emptyState
        )
    }

    // MARK: - Hero

    private struct Candidate {
        let order: Int
        let presentation: AccountPresentation
        let snapshot: UsageSnapshot
        let standing: UsageHeadroom.Standing
        let binding: UsageHeadroom.Binding
        let phase: InUsePhase
    }

    /// Accounts that may be the hero. Eligible: not paused, measured in
    /// percent, no problem state, not `.stale` (the big number must not
    /// present a failing account's last reading as current — a switch target
    /// may still be stale, the hero may not), and every considered window
    /// current. Warning lines use the same pool.
    private static func heroCandidates(
        presentations: [AccountPresentation],
        phases: [UUID: InUsePhase],
        fableCounts: (UUID) -> Bool,
        now: Date
    ) -> [Candidate] {
        var candidates: [Candidate] = []
        for (order, presentation) in presentations.enumerated() {
            guard !presentation.account.isPaused else { continue }
            guard percentProviders.contains(presentation.account.provider) else { continue }
            guard UsageHeadroom.isUsableState(presentation.state) else { continue }
            if case .stale = presentation.state { continue }
            guard let snapshot = presentation.snapshot else { continue }
            let kinds: [UsageWindowKind] = UsageHeadroom.consideredKinds(
                includeFable: fableCounts(presentation.id)
            )
            let standing = UsageHeadroom.assess(snapshot, kinds: kinds, now: now)
            guard !standing.hasUnknown, let binding = standing.binding else { continue }
            candidates.append(Candidate(
                order: order,
                presentation: presentation,
                snapshot: snapshot,
                standing: standing,
                binding: binding,
                phase: phases[presentation.id] ?? .none
            ))
        }
        return candidates
    }

    /// The pinned account when it is eligible; else the subscription used
    /// most recently — the `.inUse` account with the smallest age, else the
    /// `.lastUsed` one with the smallest age — else, with no activity at all,
    /// the least headroom. Ties keep list order.
    private static func pickHero(
        candidates: [Candidate],
        pinnedHeroID: UUID?,
        now: Date
    ) -> Hero? {
        if let pinnedHeroID, let pinned = candidates.first(where: { $0.presentation.id == pinnedHeroID }) {
            return hero(from: pinned, isPinned: true, now: now)
        }

        var inUse: (candidate: Candidate, age: TimeInterval)?
        var lastUsed: (candidate: Candidate, age: TimeInterval)?
        var leastHeadroom: Candidate?
        for candidate in candidates {
            switch candidate.phase {
            case let .inUse(age):
                if inUse == nil || age < inUse!.age { inUse = (candidate, age) }
            case let .lastUsed(age):
                if lastUsed == nil || age < lastUsed!.age { lastUsed = (candidate, age) }
            case .none:
                break
            }
            if let current = leastHeadroom, current.binding.headroom <= candidate.binding.headroom { continue }
            leastHeadroom = candidate
        }
        guard let best = inUse?.candidate ?? lastUsed?.candidate ?? leastHeadroom else { return nil }
        return hero(from: best, isPinned: false, now: now)
    }

    private static func hero(from best: Candidate, isPinned: Bool, now: Date) -> Hero {
        let bindingWindow: UsageWindow? = best.snapshot.window(for: best.binding.kind)
        var otherLimits: [Limit] = []
        for entry in best.snapshot.allWindows where entry.kind != best.binding.kind {
            // A window overtaken by its reset (e.g. a Fable percent the
            // provider stopped refreshing) would print a number that is no
            // longer true.
            guard UsageEvidence.isCurrent(
                snapshot: best.snapshot,
                windowResetsAt: entry.window.resetsAt,
                now: now
            ) else { continue }
            otherLimits.append(Limit(
                kind: entry.kind,
                label: entry.window.label,
                headroom: entry.window.remainingFraction
            ))
        }
        let tag: Hero.Tag = switch best.phase {
            case .inUse: .inUse
            case .lastUsed: .lastUsed
            case .none: .none
        }
        return Hero(
            presentation: best.presentation,
            headroom: best.binding.headroom,
            bindingKind: best.binding.kind,
            bindingLabel: bindingWindow?.label,
            tag: tag,
            isPinned: isPinned,
            resetsAt: bindingWindow?.resetsAt,
            otherLimits: otherLimits
        )
    }

    // MARK: - Warnings

    /// Uses the same `>=` comparison as `AlertTier.forUsed`, per window and
    /// per provider, over the windows the headroom judgement considers.
    private static func warning(
        for candidate: Candidate,
        thresholds: (Provider, UsageWindowKind) -> ThresholdPair
    ) -> Warning? {
        let provider: Provider = candidate.presentation.account.provider
        var crossed: (kind: UsageWindowKind, window: UsageWindow)?
        for entry in candidate.standing.known {
            let used: Double = 1 - entry.window.remainingFraction
            guard used >= thresholds(provider, entry.kind).criticalFraction else { continue }
            if let current = crossed, current.window.remainingFraction <= entry.window.remainingFraction { continue }
            crossed = entry
        }
        guard let crossed else { return nil }
        return Warning(
            presentation: candidate.presentation,
            headroom: crossed.window.remainingFraction,
            kind: crossed.kind,
            label: crossed.window.label,
            resetsAt: crossed.window.resetsAt
        )
    }

    // MARK: - Values

    static func value(
        for presentation: AccountPresentation,
        fableCounts: (UUID) -> Bool,
        now: Date
    ) -> Value {
        if presentation.account.isPaused {
            return .paused
        }
        switch presentation.state {
        case .stale, .reauthenticationRequired, .rateLimited, .integrationChanged, .unavailable:
            return .state(presentation.state)
        case .loading, .current:
            break
        }
        guard let snapshot = presentation.snapshot else { return .noData }
        if presentation.account.provider == .cursor {
            guard let spend = snapshot.cursorSpend else { return .noData }
            return .spent(cents: spend.spentCents)
        }
        let kinds: [UsageWindowKind] = UsageHeadroom.consideredKinds(
            includeFable: fableCounts(presentation.id)
        )
        let standing = UsageHeadroom.assess(snapshot, kinds: kinds, now: now)
        guard !standing.hasUnknown, let binding = standing.binding else { return .noData }
        return .headroom(binding.headroom, binding.kind)
    }

    // MARK: - Copy

    /// The hero's caption under the big number.
    static func caption(_ kind: UsageWindowKind, label: String?) -> String {
        switch kind {
        case .weekly: "of the week left"
        case .fiveHour: "of 5 hours left"
        case .modelWeekly: "of \(label ?? "Fable") left"
        }
    }

    /// A remaining share as a whole percent: "3%".
    static func percentText(_ fraction: Double) -> String {
        let scaled: Double = fraction * 100
        let whole = Int(scaled.rounded())
        return "\(whole)%"
    }

    static func dollarsText(cents: Int) -> String {
        let dollars: Double = Double(cents) / 100
        return "$" + String(format: "%.2f", dollars)
    }

    /// "resets in 11h 18m · 5h 73% left · Fable 14% left".
    static func limitsLine(resetsAt: Date?, limits: [Limit], now: Date) -> String {
        var parts: [String] = []
        if let reset = resetText(resetsAt, now: now) {
            parts.append(reset)
        }
        for limit in limits {
            parts.append("\(shortName(limit.kind, label: limit.label)) \(percentText(limit.headroom)) left")
        }
        return parts.joined(separator: " · ")
    }

    static func shortName(_ kind: UsageWindowKind, label: String?) -> String {
        switch kind {
        case .fiveHour: "5h"
        case .weekly: "week"
        case .modelWeekly: label ?? "Fable"
        }
    }

    /// "resets in 2h 27m"; nil without a reset time.
    static func resetText(_ resetsAt: Date?, now: Date) -> String? {
        guard let resetsAt else { return nil }
        return "resets in \(UsageFormatters.remainingUntilReset(resetsAt, relativeTo: now))"
    }

    /// An in-use line's right side: "25% left · 2d 2h".
    static func lineRight(headroom: Double, resetsAt: Date?, now: Date) -> String {
        let left: String = "\(percentText(headroom)) left"
        guard let resetsAt else { return left }
        return "\(left) · \(UsageFormatters.remainingUntilReset(resetsAt, relativeTo: now))"
    }

    /// A warning line's left side: "Client · 1% of the week left".
    static func warningText(label: String, headroom: Double, kind: UsageWindowKind, windowLabel: String?) -> String {
        "\(label) · \(percentText(headroom)) \(caption(kind, label: windowLabel))"
    }
}
