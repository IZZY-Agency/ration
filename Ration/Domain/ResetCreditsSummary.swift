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

    /// "↻ 2 resets · next expires in 18h · not usable yet". One catalog entry
    /// per shape (one reset or several × a countdown or a date), each with a
    /// plural for the count.
    func text(now: Date, locale: Locale = .current) -> String {
        let line: LocalizedStringResource
        if withinLeadWindow, UsageFormatters.isResetDue(soonestExpiry, relativeTo: now) {
            // Expiring this second: its own entry ("expires now") — "in" +
            // the "now" unit reads wrong in every language.
            line = totalCount > 1
                ? .resetCreditsLineNextExpiresNow(count: totalCount)
                : .resetCreditsLineExpiresNow(count: totalCount)
        } else if withinLeadWindow {
            let when: String = UsageFormatters.resetCreditRemaining(soonestExpiry, relativeTo: now, locale: locale)
            line = totalCount > 1
                ? .resetCreditsLineNextExpiresIn(count: totalCount, when)
                : .resetCreditsLineExpiresIn(count: totalCount, when)
        } else {
            let date: String = soonestExpiry.formatted(.dateTime.month(.abbreviated).day().locale(locale))
            line = totalCount > 1
                ? .resetCreditsLineNextExpiresOn(count: totalCount, date)
                : .resetCreditsLineExpiresOn(count: totalCount, date)
        }
        let usable: String = noneUsable ? LocalizedStringResource.resetCreditsLineNotUsable.string(in: locale) : ""
        return line.string(in: locale) + usable
    }

    /// The line as VoiceOver says it: words for the countdown ("in 18 hours",
    /// never "in 18h") and the month spelled out.
    func accessibilityText(now: Date, locale: Locale = .current) -> String {
        let line: LocalizedStringResource
        if withinLeadWindow, UsageFormatters.isResetDue(soonestExpiry, relativeTo: now) {
            line = totalCount > 1
                ? .resetCreditsSpokenNextExpiresNow(totalCount)
                : .resetCreditsSpokenExpiresNow(totalCount)
        } else if withinLeadWindow {
            let when: String = UsageFormatters.spokenDuration(until: soonestExpiry, relativeTo: now, locale: locale)
            line = totalCount > 1
                ? .resetCreditsSpokenNextExpiresIn(totalCount, when)
                : .resetCreditsSpokenExpiresIn(totalCount, when)
        } else {
            let date: String = soonestExpiry.formatted(.dateTime.month(.wide).day().locale(locale))
            line = totalCount > 1
                ? .resetCreditsSpokenNextExpiresOn(totalCount, date)
                : .resetCreditsSpokenExpiresOn(totalCount, date)
        }
        let usable: String = noneUsable ? LocalizedStringResource.resetCreditsSpokenNotUsable.string(in: locale) : ""
        return line.string(in: locale) + usable
    }
}
