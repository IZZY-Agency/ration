import Foundation

enum UsageFormatters {
    static func usedPercentage(
        _ fraction: Double,
        locale: Locale = .current
    ) -> String {
        fraction.formatted(
            FloatingPointFormatStyle<Double>.Percent.percent
                .locale(locale)
                .precision(.fractionLength(0))
        )
    }

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
    /// remaining, not the clock time (e.g. "4h 12m", "6d 3h", "45m", "now").
    static func remainingUntilReset(
        _ resetDate: Date,
        relativeTo now: Date = .now
    ) -> String {
        let totalSeconds = Int(resetDate.timeIntervalSince(now).rounded(.down))
        guard totalSeconds > 0 else { return "now" }

        let minutes = totalSeconds / 60
        if minutes < 60 {
            return "\(minutes)m"
        }

        let hours = minutes / 60
        if hours < 24 {
            let remainderMinutes = minutes % 60
            return remainderMinutes > 0 ? "\(hours)h \(remainderMinutes)m" : "\(hours)h"
        }

        let days = hours / 24
        let remainderHours = hours % 24
        return remainderHours > 0 ? "\(days)d \(remainderHours)h" : "\(days)d"
    }

    /// Time left on a usage-limit reset: whole days from 24 h up, whole hours
    /// below that. Coarser than `remainingUntilReset` on purpose — a reset lives
    /// for weeks, and "29d 7h" is noise that also truncates in the drop.
    static func resetCreditRemaining(_ expiresAt: Date, relativeTo now: Date = .now) -> String {
        let totalSeconds = Int(expiresAt.timeIntervalSince(now).rounded(.down))
        guard totalSeconds > 0 else { return "now" }
        guard totalSeconds >= 3_600 else { return "<1h" }
        guard totalSeconds >= 86_400 else { return "\(totalSeconds / 3_600)h" }
        return "\(totalSeconds / 86_400)d"
    }

    /// The countdown as VoiceOver should say it — "4 hours, 12 minutes", never
    /// "4h 12m". Same units and flooring as `remainingUntilReset` (days and
    /// hours from a day up, hours and minutes below), so what is heard and
    /// what is drawn never disagree about the time left. The one shared
    /// spoken formatter: every accessibility label that speaks a duration
    /// goes through here.
    static func spokenDuration(
        until date: Date,
        relativeTo now: Date = .now,
        locale: Locale = .current
    ) -> String {
        let totalSeconds = Int(date.timeIntervalSince(now).rounded(.down))
        guard totalSeconds > 0 else { return "now" }
        let totalMinutes = totalSeconds / 60
        guard totalMinutes > 0 else { return "less than a minute" }

        var components = DateComponents()
        let hours = totalMinutes / 60
        if hours >= 24 {
            components.day = hours / 24
            components.hour = hours % 24
        } else {
            components.hour = hours
            components.minute = totalMinutes % 60
        }

        let formatter = DateComponentsFormatter()
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        formatter.calendar = calendar
        formatter.unitsStyle = .full
        formatter.allowedUnits = [.day, .hour, .minute]
        formatter.maximumUnitCount = 2
        formatter.zeroFormattingBehavior = .dropAll
        return formatter.string(from: components) ?? remainingUntilReset(date, relativeTo: now)
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
