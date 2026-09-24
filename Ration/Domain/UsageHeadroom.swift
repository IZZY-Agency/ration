import Foundation

/// "How much room is left" on an account, judged the one way every surface
/// uses: each considered window through `UsageEvidence.isCurrent` against its
/// own reset, the binding one being the least remaining. Shared by
/// `SwitchAdvisor` (who to switch to) and `FocusModel` (the hero number), so
/// the two can never disagree about an account's headroom. Pure.
enum UsageHeadroom {
    struct Binding: Equatable, Sendable {
        let headroom: Double
        let kind: UsageWindowKind
    }

    struct Standing {
        /// Considered windows whose evidence is current, in binding-preference order.
        let known: [(kind: UsageWindowKind, window: UsageWindow)]
        /// Some considered window is reported but its evidence is not current.
        let hasUnknown: Bool

        /// Least remaining among known windows; on equal headroom the earlier
        /// kind in preference order (weekly > 5h > Fable) names the binding.
        var binding: Binding? {
            var result: Binding?
            for entry in known {
                let headroom: Double = entry.window.remainingFraction
                if let current = result, current.headroom <= headroom { continue }
                result = Binding(headroom: headroom, kind: entry.kind)
            }
            return result
        }
    }

    /// Preference order doubles as the copy tie-break: weekly > 5h > Fable.
    static func consideredKinds(includeFable: Bool) -> [UsageWindowKind] {
        includeFable ? [.weekly, .fiveHour, .modelWeekly] : [.weekly, .fiveHour]
    }

    static func assess(
        _ snapshot: UsageSnapshot,
        kinds: [UsageWindowKind],
        now: Date
    ) -> Standing {
        var known: [(kind: UsageWindowKind, window: UsageWindow)] = []
        var hasUnknown = false
        for kind in kinds {
            guard let window = snapshot.window(for: kind) else { continue }
            let current: Bool = UsageEvidence.isCurrent(
                snapshot: snapshot,
                windowResetsAt: window.resetsAt,
                now: now
            )
            if current {
                known.append((kind, window))
            } else {
                hasUnknown = true
            }
        }
        return Standing(known: known, hasUnknown: hasUnknown)
    }

    /// Accounts with a problem the user must resolve first. `.loading` /
    /// `.stale` are left to the evidence rule — every poll passes through
    /// `.loading`, and gating on it would flicker.
    static func isUsableState(_ state: AccountViewState) -> Bool {
        switch state {
        case .loading, .current, .stale:
            return true
        case .reauthenticationRequired, .rateLimited, .integrationChanged, .unavailable:
            return false
        }
    }
}
