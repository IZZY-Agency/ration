import Foundation

struct SoonestReset: Equatable, Sendable {
    let accountLabel: String
    let kind: UsageWindowKind
    let resetsAt: Date
    /// The API-provided window label (e.g. "Fable" for `.modelWeekly`). `.fiveHour`
    /// and `.weekly` windows typically carry no label and render fixed "5H"/"WK"
    /// text instead; `.modelWeekly` has no fixed text, so callers fall back to
    /// this label (or a generic "Fable") when rendering.
    let label: String?
}

extension SoonestReset {
    /// The header's next-reset line as VoiceOver says it — "Next reset, Max
    /// weekly, in 45 minutes" — never the drawn "WK · 45m".
    func accessibilityLabel(now: Date, locale: Locale = .current) -> String {
        let when = UsageFormatters.spokenDuration(until: resetsAt, relativeTo: now, locale: locale)
        return "Next reset, \(accountLabel) \(kind.spokenName(label: label)), in \(when)"
    }
}

/// The single nearest upcoming window reset across all accounts and all window
/// kinds. Pure; ignores nil and past resets; ties resolve to presentation order.
enum SoonestResetSummary {
    static func next(from presentations: [AccountPresentation], now: Date) -> SoonestReset? {
        var best: SoonestReset?
        for presentation in presentations {
            // Driven by the canonical collection rather than a hand-listed
            // tuple: a kind missing from that list would silently never be
            // eligible to be the soonest reset.
            for (kind, window) in presentation.snapshot?.allWindows ?? [] {
                guard let resetsAt = window.resetsAt, resetsAt > now else { continue }
                if best == nil || resetsAt < best!.resetsAt {
                    best = SoonestReset(
                        accountLabel: presentation.account.label,
                        kind: kind,
                        resetsAt: resetsAt,
                        label: window.label
                    )
                }
            }
        }
        return best
    }
}
