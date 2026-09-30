import Foundation

/// The words plan value is shown in (EN/FR/UK). Pure: each function takes
/// the locale, so tests pin one.
enum TokenBurnCopy {
    /// "$306.56", "≥ $13,116.77" (at least: some tokens unpriced or assumed).
    static func amount(cents: Decimal, atLeast: Bool, locale: Locale = .current) -> String {
        let whole = Int(NSDecimalNumber(decimal: cents).doubleValue.rounded())
        let text = UsageFormatters.usd(cents: whole, grouped: true, locale: locale)
        return atLeast ? "≥\u{00A0}" + text : text
    }

    /// The card's line: per account only the
    /// time since Ration started tracking, so a period that began before
    /// that says "since <time>", never the whole period.
    /// "≥ $287.03 at API prices · since Sep 29, 22:14"; "… · last 30 days".
    static func cardLine(_ value: AccountPlanValue, trackingSince: Date?, locale: Locale = .current,
                         calendar: Calendar = .current) -> String {
        guard let trackingSince else { return LocalizedStringResource.tokenBurnCardNotTracked.string(in: locale) }
        let hasUse = value.value.replies > 0
        let amount = amount(cents: value.value.cents, atLeast: value.isAtLeast, locale: locale)
        if isPartial(value.period, trackingSince: trackingSince) {
            let since = moment(trackingSince, locale: locale, calendar: calendar)
            return hasUse ? LocalizedStringResource.tokenBurnCardValueSince(amount, since).string(in: locale)
                : LocalizedStringResource.tokenBurnCardNoneSince(since).string(in: locale)
        }
        let phrase = phrase(value.period.kind, locale: locale)
        return hasUse ? LocalizedStringResource.tokenBurnCardValue(amount, phrase).string(in: locale)
            : LocalizedStringResource.tokenBurnCardNone(phrase).string(in: locale)
    }

    /// Tracking began inside the period: per account, only part of it counts.
    static func isPartial(_ period: TokenBurnPeriod, trackingSince: Date?) -> Bool {
        guard let trackingSince else { return true }
        return trackingSince > period.start
    }

    /// The popover's line under the Claude header: all use in the period.
    static func totalLine(_ total: PlanValue, choice: TokenBurnPeriod.Choice, locale: Locale = .current) -> String {
        LocalizedStringResource.tokenBurnTotalLine(amount(cents: total.cents, atLeast: !total.isComplete, locale: locale),
                                                    phrase(choice, locale: locale)).string(in: locale)
    }

    /// The chosen period inside a sentence.
    static func phrase(_ choice: TokenBurnPeriod.Choice, locale: Locale = .current) -> String {
        switch choice {
        case .last7Days: phrase(.days(7), locale: locale)
        case .last30Days: phrase(.days(30), locale: locale)
        case .thisMonth: phrase(.month, locale: locale)
        case .billingCycle: phrase(.cycle, locale: locale)
        }
    }

    /// Why per-account figures start later than the total.
    static func perAccountNote(trackingSince: Date?, locale: Locale = .current, calendar: Calendar = .current) -> String {
        guard let trackingSince else { return LocalizedStringResource.tokenBurnPerAccountNoteNotYet.string(in: locale) }
        return LocalizedStringResource.tokenBurnPerAccountNote(moment(trackingSince, locale: locale, calendar: calendar))
            .string(in: locale)
    }

    /// The period inside a sentence: "last 30 days", "this billing cycle".
    static func phrase(_ kind: TokenBurnPeriod.Kind, locale: Locale = .current) -> String {
        switch kind {
        case .days(7): LocalizedStringResource.tokenBurnPeriodLast7DaysPhrase.string(in: locale)
        case .days: LocalizedStringResource.tokenBurnPeriodLast30DaysPhrase.string(in: locale)
        case .month: LocalizedStringResource.tokenBurnPeriodMonthPhrase.string(in: locale)
        case .cycle: LocalizedStringResource.tokenBurnPeriodCyclePhrase.string(in: locale)
        }
    }

    /// The current period's row title: "Last 30 days", "This billing cycle".
    static func title(_ kind: TokenBurnPeriod.Kind, locale: Locale = .current) -> String {
        switch kind {
        case .days(7): LocalizedStringResource.tokenBurnPeriodLast7DaysTitle.string(in: locale)
        case .days: LocalizedStringResource.tokenBurnPeriodLast30DaysTitle.string(in: locale)
        case .month: LocalizedStringResource.tokenBurnPeriodThisMonthTitle.string(in: locale)
        case .cycle: LocalizedStringResource.tokenBurnPeriodCycleTitle.string(in: locale)
        }
    }

    /// The period picker's options.
    static func choice(_ choice: TokenBurnPeriod.Choice, locale: Locale = .current) -> String {
        switch choice {
        case .last7Days: LocalizedStringResource.tokenBurnPeriodLast7DaysTitle.string(in: locale)
        case .last30Days: LocalizedStringResource.tokenBurnPeriodLast30DaysTitle.string(in: locale)
        case .thisMonth: LocalizedStringResource.tokenBurnPeriodThisMonthTitle.string(in: locale)
        case .billingCycle: LocalizedStringResource.tokenBurnPeriodBillingCycleTitle.string(in: locale)
        }
    }

    /// "Sep 1 – 30": the period's days (its end is exclusive).
    static func range(_ period: TokenBurnPeriod, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let formatter = DateIntervalFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateTemplate = "MMMd"
        return formatter.string(from: period.start, to: period.end.addingTimeInterval(-1))
    }

    /// "Sep 29, 22:14".
    static func moment(_ date: Date, locale: Locale = .current, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return formatter.string(from: date)
    }

    /// "1.53×" in the language's decimal separator.
    static func ratio(_ ratio: Decimal, locale: Locale = .current) -> String {
        let language = LocalizedCopy.shippedLocale(for: locale).language.languageCode?.identifier ?? "en"
        let number = ratio.formatted(Decimal.FormatStyle(locale: Locale(identifier: language)).precision(.fractionLength(2)))
        return number + "×"
    }

    /// "783.8M" tokens, in the language's compact form.
    static func tokens(_ count: Int, locale: Locale = .current) -> String {
        let language = LocalizedCopy.shippedLocale(for: locale).language.languageCode?.identifier ?? "en"
        return count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1))
            .locale(Locale(identifier: language)))
    }

    /// "claude-opus-5-5" → "Opus 5.5"; "claude-haiku-4-5-20251001" → "Haiku 4.5".
    /// Model names are never translated; an id of another shape is shown as is.
    static func modelName(_ id: String) -> String {
        guard id.hasPrefix("claude-") else { return id }
        var parts = id.dropFirst("claude-".count).split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) { parts.removeLast() }
        guard let family = parts.first, family.allSatisfy(\.isLetter), parts.count > 1,
              parts.dropFirst().allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return id }
        return family.prefix(1).uppercased() + family.dropFirst() + " " + parts.dropFirst().joined(separator: ".")
    }

    /// A line for use on no single account.
    static func owner(_ owner: TokenBurnOwner, locale: Locale = .current) -> String? {
        switch owner {
        case .beforeTracking: LocalizedStringResource.tokenBurnBeforeTracking.string(in: locale)
        case .notObserved: LocalizedStringResource.tokenBurnOwnerNotObserved.string(in: locale)
        case .unassigned: LocalizedStringResource.tokenBurnOwnerUnassigned.string(in: locale)
        case .apiKey: LocalizedStringResource.tokenBurnOwnerApiKey.string(in: locale)
        case .unclassified: LocalizedStringResource.tokenBurnOwnerUnclassified.string(in: locale)
        case .account: nil
        }
    }
}
