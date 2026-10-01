import Foundation

/// Code-built Settings copy that several panes share, each with a `locale:`
/// so tests can pin a language (the default is the running one).
enum SettingsCopy {
    /// A rate window's name in Settings rows and pickers. Fable is a model
    /// name and stays as is.
    static func windowLabel(_ window: UsageWindowKind, locale: Locale = .current) -> String {
        switch window {
        case .fiveHour: LocalizedStringResource.settingsWindowFiveHour.string(in: locale)
        case .weekly: LocalizedStringResource.settingsWindowWeekly.string(in: locale)
        case .modelWeekly: "Fable"
        }
    }

    /// The Notify checkbox's tooltip while notifications can be delivered.
    static func notifyHelp(locale: Locale = .current) -> String {
        LocalizedStringResource.alertsNotifyHelp.string(in: locale)
    }

    /// A reset credit's row title: the provider's own name for it, verbatim,
    /// or a generic one.
    static func resetCreditTitle(_ title: String?, locale: Locale = .current) -> String {
        if let title { return title }
        return LocalizedStringResource.accountResetCreditUntitled.string(in: locale)
    }

    /// "×2 · expires Oct 3, 2026 at 2:00 PM".
    static func resetCreditLine(
        count: Int,
        expiresAt: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            .locale(LocalizedCopy.shippedLocale(for: locale))
        style.timeZone = timeZone
        let when: String = expiresAt.formatted(style)
        return LocalizedStringResource.accountResetCreditLine(count, when).string(in: locale)
    }

    // MARK: Usage credits

    static func usageCreditsBalanceLabel(locale: Locale = .current) -> String {
        LocalizedStringResource.accountUsageCreditsBalance.string(in: locale)
    }

    static func usageCreditsSwitchLabel(locale: Locale = .current) -> String {
        LocalizedStringResource.accountUsageCreditsSwitchLabel.string(in: locale)
    }

    static func usageCreditsSwitch(_ enabled: Bool, locale: Locale = .current) -> String {
        enabled
            ? LocalizedStringResource.accountUsageCreditsSwitchOn.string(in: locale)
            : LocalizedStringResource.accountUsageCreditsSwitchOff.string(in: locale)
    }

    static func usageCreditsKind(_ kind: UsageCreditGrant.Kind, locale: Locale = .current) -> String {
        switch kind {
        case .promotional: LocalizedStringResource.accountUsageCreditsKindPromotional.string(in: locale)
        case .purchased: LocalizedStringResource.accountUsageCreditsKindPurchased.string(in: locale)
        case .free: LocalizedStringResource.accountUsageCreditsKindFree.string(in: locale)
        }
    }

    /// "€10.00 left of €10.00 · expires May 27, 2027 at 2:00 AM" (or "· no expiry").
    static func usageCreditsGrantLine(
        _ grant: UsageCreditGrant,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let left: String = UsageFormatters.money(grant.remaining, locale: locale)
        let granted: String? = grant.granted.map { UsageFormatters.money($0, locale: locale) }
        guard let expiresAt = grant.expiresAt else {
            return (granted.map { LocalizedStringResource.accountUsageCreditsGrantLineNoExpiry(left, $0) }
                ?? .accountUsageCreditsGrantLineNoExpiryLeft(left)).string(in: locale)
        }
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            .locale(LocalizedCopy.shippedLocale(for: locale))
        style.timeZone = timeZone
        let when: String = expiresAt.formatted(style)
        return (granted.map { LocalizedStringResource.accountUsageCreditsGrantLine(left, $0, when) }
            ?? .accountUsageCreditsGrantLineLeft(left, when)).string(in: locale)
    }

    static func usageCreditsFootnote(locale: Locale = .current) -> String {
        LocalizedStringResource.accountUsageCreditsFootnote.string(in: locale)
    }

    /// "Read 3 minutes ago."
    static func usageCreditsRead(_ fetchedAt: Date, now: Date, locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = LocalizedCopy.shippedLocale(for: locale)
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .named
        let relative: String = formatter.localizedString(for: fetchedAt, relativeTo: now)
        return LocalizedStringResource.accountUsageCreditsRead(relative).string(in: locale)
    }

    static func usageCreditsPartial(locale: Locale = .current) -> String {
        LocalizedStringResource.accountUsageCreditsPartial.string(in: locale)
    }

    static func resetCreditUsability(_ usable: Bool, locale: Locale = .current) -> String {
        usable
            ? LocalizedStringResource.accountResetCreditUsableNow.string(in: locale)
            : LocalizedStringResource.accountResetCreditNotUsableYet.string(in: locale)
    }
}

/// TypeSafe's account Settings copy.
enum TypeSafeSettingsCopy {
    static func sectionTitle(locale: Locale = .current) -> String {
        LocalizedStringResource.settingsSectionTypeSafeSpend.string(in: locale)
    }

    static func thisCycleLabel(locale: Locale = .current) -> String {
        LocalizedStringResource.accountTypeSafeThisCycle.string(in: locale)
    }

    /// "$3.41 · September 2026 · resets in 1d". The month is Ration's own,
    /// in the app language, from the reset date (the cycle is the calendar
    /// month before it); TypeSafe's English `cycleLabel` only when there is no
    /// reset date.
    static func thisCycle(_ spend: TypeSafeSpend, now: Date, locale: Locale = .current) -> String {
        var parts: [String] = [UsageFormatters.money(spend.cycleSpent, locale: locale)]
        if let resetsAt = spend.resetsAt {
            var style = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.wide).year()
            style.locale = LocalizedCopy.shippedLocale(for: locale)
            parts.append(resetsAt.addingTimeInterval(-3600).formatted(style))
        } else if let label = spend.cycleLabel, !label.isEmpty {
            parts.append(label)
        }
        var text = parts.joined(separator: " · ")
        if let resetsAt = spend.resetsAt, resetsAt > now {
            text += LocalizedStringResource.typeSafeCardResetsIn(UsageFormatters.resetCreditRemaining(resetsAt, relativeTo: now, locale: locale)).string(in: locale)
        }
        return text
    }

    static func autoRechargeLabel(locale: Locale = .current) -> String {
        LocalizedStringResource.accountTypeSafeAutoRecharge.string(in: locale)
    }

    static func autoRecharge(_ on: Bool, locale: Locale = .current) -> String {
        on
            ? LocalizedStringResource.accountTypeSafeAutoRechargeOn.string(in: locale)
            : LocalizedStringResource.accountTypeSafeAutoRechargeOff.string(in: locale)
    }

    static func last30DaysLabel(locale: Locale = .current) -> String {
        LocalizedStringResource.accountTypeSafeLast30Days.string(in: locale)
    }

    /// "88.6M input tokens · 78,571 requests · ≈ $3.49" over the days read
    /// (the console returns the last 30).
    static func last30Days(_ days: [TypeSafeDay], locale: Locale = .current) -> String {
        let input = days.reduce(0) { $0 &+ $1.inputTokens }
        let requests = days.reduce(0) { $0 &+ $1.requests }
        let cents = TypeSafeBilling.usd(TypeSafePrice.estimate(inputTokens: input))
        let dollars: String = cents.map { UsageFormatters.money($0, locale: locale) } ?? "—"
        return LocalizedStringResource.accountTypeSafeLast30DaysValue(
            UsageFormatters.tokenCount(input, locale: locale),
            UsageFormatters.creditCount(Decimal(requests), locale: locale),
            dollars
        ).string(in: locale)
    }

    static func estimateNote(locale: Locale = .current) -> String {
        let price = Money(minorUnits: 42, currency: "USD", exponent: 3)!
        return LocalizedStringResource.accountTypeSafeEstimateNote(UsageFormatters.money(price, locale: locale)).string(in: locale)
    }

    static func creditsFootnote(locale: Locale = .current) -> String {
        LocalizedStringResource.accountTypeSafeCreditsFootnote.string(in: locale)
    }
}
