import Foundation

/// The usage credits line on a Claude card: "Credits €10.00 · off", or with
/// the part inside its expiry warning window ("· expires in 18h").
struct UsageCreditsSummary: Equatable {
    struct Expiring: Equatable {
        /// Every grant inside its warning window, summed.
        let amount: Money
        /// The soonest of their expiries.
        let expiresAt: Date
        /// The whole balance expires: the line names no amount.
        let wholeBalance: Bool
    }

    let balance: Money
    /// claude.ai's switch is known to be off; unknown reads as on.
    let switchOff: Bool
    let expiring: Expiring?
    /// Read longer ago than `UsageEvidence.maxAge`: drawn faint.
    let isOld: Bool
    let fetchedAt: Date

    /// A reading this old no longer shows on the card at all.
    static let hideAfter: TimeInterval = 24 * 3600

    /// nil: nothing to show (never read, read too long ago, or no money).
    /// `verified` (`UsageSnapshot.usageCreditsVerified`): only then does the
    /// line warn about an expiry; otherwise it shows the balance alone.
    static func make(credits: UsageCredits?, enabled: Bool?, leadDays: Int, now: Date, verified: Bool = true) -> UsageCreditsSummary? {
        guard let credits else { return nil }
        let age = now.timeIntervalSince(credits.fetchedAt)
        guard age <= hideAfter else { return nil }
        let unexpired = credits.grants(unexpiredAt: now)
        guard credits.balance.minorUnits > 0 || !unexpired.isEmpty else { return nil }
        let inWindow = verified ? unexpired.filter { UsageCreditPolicy.isWithinLeadWindow($0, leadDays: leadDays, now: now) } : []
        var expiring: Expiring?
        if let soonest = inWindow.min(by: { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }),
           let expiresAt = soonest.expiresAt {
            let amount = Money.sum(inWindow.map(\.remaining)) ?? soonest.remaining
            expiring = Expiring(amount: amount, expiresAt: expiresAt, wholeBalance: amount.minorUnits >= credits.balance.minorUnits)
        }
        return UsageCreditsSummary(
            balance: credits.balance,
            switchOff: enabled == false,
            expiring: expiring,
            isOld: age > UsageEvidence.maxAge,
            fetchedAt: credits.fetchedAt
        )
    }

    func text(now: Date, locale: Locale = .current) -> String {
        var line: String = LocalizedStringResource.usageCreditsLineBalance(UsageFormatters.money(balance, locale: locale)).string(in: locale)
        if switchOff {
            line += LocalizedStringResource.usageCreditsLineOff.string(in: locale)
        }
        if let expiring {
            let due = UsageFormatters.isResetDue(expiring.expiresAt, relativeTo: now)
            let when: String = UsageFormatters.resetCreditRemaining(expiring.expiresAt, relativeTo: now, locale: locale)
            let amount: String = UsageFormatters.money(expiring.amount, locale: locale)
            let tail: LocalizedStringResource = switch (expiring.wholeBalance, due) {
            case (true, true): .usageCreditsLineExpiresNow
            case (true, false): .usageCreditsLineExpiresIn(when)
            case (false, true): .usageCreditsLinePartExpiresNow(amount)
            case (false, false): .usageCreditsLinePartExpiresIn(amount, when)
            }
            line += tail.string(in: locale)
        }
        return line
    }

    /// The line as VoiceOver says it: whole sentences, the countdown in
    /// words, and when it was read if that was a while ago.
    func accessibilityText(now: Date, locale: Locale = .current) -> String {
        var text: String = LocalizedStringResource.usageCreditsSpokenBalance(UsageFormatters.money(balance, locale: locale)).string(in: locale)
        if switchOff {
            text += LocalizedStringResource.usageCreditsSpokenOff.string(in: locale)
        }
        if let expiring {
            let due = UsageFormatters.isResetDue(expiring.expiresAt, relativeTo: now)
            let when: String = UsageFormatters.spokenDuration(until: expiring.expiresAt, relativeTo: now, locale: locale)
            let amount: String = UsageFormatters.money(expiring.amount, locale: locale)
            let tail: LocalizedStringResource = switch (expiring.wholeBalance, due) {
            case (true, true): .usageCreditsSpokenExpiresNow
            case (true, false): .usageCreditsSpokenExpiresIn(when)
            case (false, true): .usageCreditsSpokenPartExpiresNow(amount)
            case (false, false): .usageCreditsSpokenPartExpiresIn(amount, when)
            }
            text += tail.string(in: locale)
        }
        if isOld {
            let time: String = fetchedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(locale))
            text += LocalizedStringResource.usageCreditsSpokenLastRead(time).string(in: locale)
        }
        return text
    }
}

/// The Codex credits line on a ChatGPT card: "Credits 120" or "Credits
/// unlimited". Nothing when there is nothing to show, or the reading is more
/// than a day old.
enum CodexCreditsCopy {
    static func shows(_ credits: CodexCredits?, now: Date) -> Bool {
        guard let credits, credits.isShown else { return false }
        return now.timeIntervalSince(credits.fetchedAt) <= UsageCreditsSummary.hideAfter
    }

    static func line(_ credits: CodexCredits, locale: Locale = .current) -> String {
        credits.unlimited
            ? LocalizedStringResource.codexCreditsLineUnlimited.string(in: locale)
            : LocalizedStringResource.usageCreditsLineBalance(UsageFormatters.creditCount(credits.balance, locale: locale)).string(in: locale)
    }

    static func spoken(_ credits: CodexCredits, locale: Locale = .current) -> String {
        credits.unlimited
            ? LocalizedStringResource.codexCreditsSpokenUnlimited.string(in: locale)
            : LocalizedStringResource.codexCreditsSpokenBalance(UsageFormatters.creditCount(credits.balance, locale: locale)).string(in: locale)
    }

    /// Settings value: the count, or "Unlimited".
    static func settingsValue(_ credits: CodexCredits, locale: Locale = .current) -> String {
        credits.unlimited
            ? LocalizedStringResource.accountCodexCreditsUnlimited.string(in: locale)
            : UsageFormatters.creditCount(credits.balance, locale: locale)
    }

    static func footnote(locale: Locale = .current) -> String {
        LocalizedStringResource.accountCodexCreditsFootnote.string(in: locale)
    }
}
