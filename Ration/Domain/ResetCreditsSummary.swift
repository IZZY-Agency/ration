import Foundation

/// The one-line reset summary on an account card.
struct ResetCreditsSummary: Equatable {
    let totalCount: Int
    let soonestExpiry: Date
    let withinLeadWindow: Bool
    /// True only when EVERY reset is known not usable right now.
    let noneUsable: Bool

    static func make(credits: ResetCredits?, leadDays: Int, now: Date) -> ResetCreditsSummary? {
        let items = credits?.unexpired(at: now) ?? []
        guard let soonest = items.min(by: { $0.expiresAt < $1.expiresAt }) else { return nil }
        return ResetCreditsSummary(
            totalCount: items.reduce(0) { $0 + $1.count },
            soonestExpiry: soonest.expiresAt,
            withinLeadWindow: ResetCreditPolicy.isWithinLeadWindow(soonest, leadDays: leadDays, now: now),
            noneUsable: items.allSatisfy { $0.usableNow == false }
        )
    }

    func text(now: Date) -> String {
        let noun = totalCount == 1 ? "reset" : "resets"
        let next = totalCount > 1 ? "next " : ""
        let when = withinLeadWindow
            ? "in \(UsageFormatters.resetCreditRemaining(soonestExpiry, relativeTo: now))"
            : soonestExpiry.formatted(.dateTime.month(.abbreviated).day())
        let usable = noneUsable ? " · not usable yet" : ""
        return "↻ \(totalCount) \(noun) · \(next)expires \(when)\(usable)"
    }
}
