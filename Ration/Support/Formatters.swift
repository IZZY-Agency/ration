import Foundation

enum UsageFormatters {
    /// A used share as prose — VoiceOver labels and sentences: the locale's
    /// percent rules. In French only, the space before "%" is normalised to
    /// the narrow no-break space (U+202F) typography asks for, whichever
    /// no-break space the OS's locale data uses.
    static func usedPercentage(
        _ fraction: Double,
        locale: Locale = .current
    ) -> String {
        let formatted = fraction.formatted(
            FloatingPointFormatStyle<Double>.Percent.percent
                .locale(locale)
                .precision(.fractionLength(0))
        )
        guard locale.language.languageCode == .french else { return formatted }
        return formatted.replacingOccurrences(of: nbsp, with: narrowNbsp)
    }

    /// A used share as drawn in a compact monospaced cell ("85%"; "85 %" in
    /// French). Space Mono and JetBrains Mono have no U+202F glyph, so the
    /// French space is a full no-break space (U+00A0). Same rounding as
    /// `usedPercentage`.
    static func compactUsedPercentage(
        _ fraction: Double,
        locale: Locale = .current
    ) -> String {
        usedPercentage(fraction, locale: locale)
            .replacingOccurrences(of: narrowNbsp, with: nbsp)
    }

    /// An already-rounded whole percent for a compact cell ("3%"; "3 %" in
    /// French, U+00A0 as in `compactUsedPercentage`). Never grouped.
    /// Formatted for the app language alone, so English in a European region
    /// still draws 1.3.0's "85%", never the region's "85 %".
    static func compactPercent(_ whole: Int, locale: Locale = .current) -> String {
        let style = IntegerFormatStyle<Int>.Percent(locale: languageLocale(for: locale)).grouping(.never)
        return whole.formatted(style)
            .replacingOccurrences(of: narrowNbsp, with: nbsp)
    }

    /// A US-dollar amount (Cursor bills in dollars): exactly two decimals,
    /// never grouped, with the app language's decimal separator — "$12.50",
    /// "12,50 $" (fr, uk). Only the LANGUAGE picks the separator, never the
    /// region, so English stays "$12.50" in every region; the symbol's side
    /// is the catalog's `currency.usd`.
    ///
    /// `alertStyle` is the alert and drop form: thousands grouped, and no
    /// ".00" on a whole-dollar amount ("$50", "$1,234.05"), as those texts
    /// read in 1.3.0.
    static func usd(cents: Int, alertStyle: Bool = false, locale: Locale = .current) -> String {
        let shipped: Locale = LocalizedCopy.shippedLocale(for: locale)
        let languageCode: String = shipped.language.languageCode?.identifier ?? "en"
        let numberLocale = Locale(identifier: languageCode)
        let amount: Decimal = Decimal(cents) / 100
        let fractionDigits: Int = alertStyle && cents % 100 == 0 ? 0 : 2
        let grouping: Decimal.FormatStyle.Configuration.Grouping = alertStyle ? .automatic : .never
        let style = Decimal.FormatStyle(locale: numberLocale)
            .precision(.fractionLength(fractionDigits))
            .grouping(grouping)
        let number: String = amount.formatted(style)
        return LocalizedStringResource.currencyUsd(number).string(in: locale)
    }

    /// A whole percent for text Ration draws in its own faces: "42%", French
    /// "42 %" — U+202F in the display face, U+00A0 in the monospaced one
    /// (Space Mono and JetBrains Mono have no U+202F glyph). Formatted for
    /// the app language alone, so the region never changes English.
    static func wholePercent(_ whole: Int, monospaced: Bool, locale: Locale = .current) -> String {
        let compact: String = compactPercent(whole, locale: locale)
        guard !monospaced, languageLocale(for: locale).language.languageCode == .french else { return compact }
        return compact.replacingOccurrences(of: nbsp, with: narrowNbsp)
    }

    /// One decimal, rounded exactly as `%.1f` prints it (1.3.0's form), with
    /// the app language's decimal separator: "1.5", "1,5".
    static func oneDecimal(_ value: Double, locale: Locale = .current) -> String {
        let posix: String = String(format: "%.1f", value)
        let separator: String = languageLocale(for: locale).decimalSeparator ?? "."
        guard separator != "." else { return posix }
        return posix.replacingOccurrences(of: ".", with: separator)
    }

    /// The app language as a region-free locale ("fr", "uk", "en").
    private static func languageLocale(for locale: Locale) -> Locale {
        let shipped: Locale = LocalizedCopy.shippedLocale(for: locale)
        return Locale(identifier: shipped.language.languageCode?.identifier ?? "en")
    }

    private static let nbsp = "\u{00A0}"
    private static let narrowNbsp = "\u{202F}"

    static func relativeReset(
        _ resetDate: Date,
        relativeTo now: Date = .now,
        locale: Locale = .current
    ) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: resetDate, relativeTo: now)
    }

    static func exactReset(
        _ resetDate: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
            .locale(locale)
        style.timeZone = timeZone
        return resetDate.formatted(style)
    }

    static func compactReset(
        _ resetDate: Date,
        relativeTo now: Date = .now,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        let relative = relativeReset(
            resetDate,
            relativeTo: now,
            locale: locale
        )
        let exact = exactReset(
            resetDate,
            locale: locale,
            timeZone: timeZone
        )
        return "\(relative) · \(exact)"
    }

    /// A short clock-time string with no date component (e.g. "3:45 PM"),
    /// used for compact in-card annotations like a projected exhaustion time.
    static func shortTime(
        _ date: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var style = Date.FormatStyle(date: .omitted, time: .shortened)
            .locale(locale)
        style.timeZone = timeZone
        return date.formatted(style)
    }

    /// A short countdown to the reset for the compact ledger — the time
    /// remaining, not the clock time (e.g. "4h 12m", "6d 3h", "45m", "now";
    /// "4 h 12 min" in French, "4 год 12 хв" in Ukrainian). The units are
    /// catalog entries, not `Duration.UnitsFormatStyle`, so the drawn text is
    /// the same on every OS release.
    static func remainingUntilReset(
        _ resetDate: Date,
        relativeTo now: Date = .now,
        locale: Locale = .current
    ) -> String {
        let totalSeconds = Int(resetDate.timeIntervalSince(now).rounded(.down))
        guard totalSeconds > 0 else { return unit(.unitNow, locale) }

        let minutes = totalSeconds / 60
        if minutes < 60 {
            return unit(.unitMinutesShort(minutes), locale)
        }

        let hours = minutes / 60
        if hours < 24 {
            let remainderMinutes = minutes % 60
            guard remainderMinutes > 0 else { return unit(.unitHoursShort(hours), locale) }
            return unit(.unitHoursMinutesShort(hours, remainderMinutes), locale)
        }

        let days = hours / 24
        let remainderHours = hours % 24
        guard remainderHours > 0 else { return unit(.unitDaysShort(days), locale) }
        return unit(.unitDaysHoursShort(days, remainderHours), locale)
    }

    /// `remainingUntilReset` cut to its leading unit, floored: "12 h" for
    /// 12 h 30 min, "3 j" for 3 j 4 h, "0 min" when the reset is due. The
    /// fallback for a column too narrow for the full countdown (the attention
    /// drop's, in French and Ukrainian); the full form stays the tooltip.
    static func remainingUntilResetLeadingUnit(
        _ resetDate: Date,
        relativeTo now: Date = .now,
        locale: Locale = .current
    ) -> String {
        let totalSeconds = max(0, Int(resetDate.timeIntervalSince(now).rounded(.down)))
        let minutes = totalSeconds / 60
        if minutes < 60 { return unit(.unitMinutesShort(minutes), locale) }
        let hours = minutes / 60
        if hours < 24 { return unit(.unitHoursShort(hours), locale) }
        return unit(.unitDaysShort(hours / 24), locale)
    }

    /// Time left on a usage-limit reset: whole days from 24 h up, whole hours
    /// below that. Coarser than `remainingUntilReset` on purpose — a reset lives
    /// for weeks, and "29d 7h" is noise that also truncates in the drop.
    static func resetCreditRemaining(
        _ expiresAt: Date,
        relativeTo now: Date = .now,
        locale: Locale = .current
    ) -> String {
        let totalSeconds = Int(expiresAt.timeIntervalSince(now).rounded(.down))
        guard totalSeconds > 0 else { return unit(.unitNow, locale) }
        guard totalSeconds >= 3_600 else { return unit(.unitUnderHour, locale) }
        guard totalSeconds >= 86_400 else { return unit(.unitHoursShort(totalSeconds / 3_600), locale) }
        return unit(.unitDaysShort(totalSeconds / 86_400), locale)
    }

    /// Whether a reset has arrived — exactly when the countdowns above draw
    /// their "now" word, by the same flooring. Callers branch on this, never
    /// on the drawn text, which differs per language.
    static func isResetDue(_ resetDate: Date, relativeTo now: Date) -> Bool {
        Int(resetDate.timeIntervalSince(now).rounded(.down)) <= 0
    }

    /// A compact unit string from the catalog, in `locale`'s language.
    private static func unit(_ resource: LocalizedStringResource, _ locale: Locale) -> String {
        resource.string(in: locale)
    }

    /// The countdown as VoiceOver should say it — "4 hours, 12 minutes", never
    /// "4h 12m". Same units and flooring as `remainingUntilReset` (days and
    /// hours from a day up, hours and minutes below), so what is heard and
    /// what is drawn never disagree about the time left. The one shared
    /// spoken formatter: every accessibility label that speaks a duration
    /// goes through here.
    ///
    /// The words are catalog plural entries, not `DateComponentsFormatter`,
    /// for the same reason as the compact units: the output is the same on
    /// every OS release. Every caller puts it after "in" (fr "dans", uk
    /// "через"), so the Ukrainian forms are the ones that follow "через".
    static func spokenDuration(
        until date: Date,
        relativeTo now: Date = .now,
        locale: Locale = .current
    ) -> String {
        let totalSeconds = Int(date.timeIntervalSince(now).rounded(.down))
        guard totalSeconds > 0 else { return unit(.unitNowSpoken, locale) }
        let totalMinutes = totalSeconds / 60
        guard totalMinutes > 0 else { return unit(.unitUnderMinuteSpoken, locale) }

        let hours = totalMinutes / 60
        if hours >= 24 {
            let days: String = unit(.unitDaysSpoken(hours / 24), locale)
            let remainderHours = hours % 24
            guard remainderHours > 0 else { return days }
            return unit(.unitPairSpoken(days, unit(.unitHoursSpoken(remainderHours), locale)), locale)
        }
        let minutes: String = unit(.unitMinutesSpoken(totalMinutes % 60), locale)
        guard hours > 0 else { return minutes }
        let hoursText: String = unit(.unitHoursSpoken(hours), locale)
        guard totalMinutes % 60 > 0 else { return hoursText }
        return unit(.unitPairSpoken(hoursText, minutes), locale)
    }

    /// The reset as a compact absolute time — "Jan 15, 12:12 PM" — for the
    /// countdown's click-to-reveal state, where the full `exactReset` (with
    /// the year) would not fit the column.
    static func shortReset(
        _ resetDate: Date,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
            .locale(locale)
        style.timeZone = timeZone
        return resetDate.formatted(style)
    }
}
