import Foundation

/// The account pane's "Recent warm-ups" lines: "Today 14:02 · sent",
/// "Yesterday 09:00 · refused (429)". Plain words for each kind; a status
/// code only where Claude sent one.
enum WarmUpOutcomeCopy {
    static func title(locale: Locale = .current) -> String {
        LocalizedStringResource.accountWarmUpsTitle.string(in: locale)
    }

    static func empty(locale: Locale = .current) -> String {
        LocalizedStringResource.accountWarmUpsEmpty.string(in: locale)
    }

    /// Newest first, as the list shows them.
    static func lines(
        _ outcomes: [WarmUpOutcome],
        now: Date,
        locale: Locale = .current,
        calendar: Calendar = .autoupdatingCurrent
    ) -> [String] {
        outcomes.reversed().map { outcome in
            line(outcome, now: now, locale: locale, calendar: calendar)
        }
    }

    static func line(
        _ outcome: WarmUpOutcome,
        now: Date,
        locale: Locale = .current,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let when = self.when(outcome.at, now: now, locale: locale, calendar: calendar)
        let what = self.what(outcome, locale: locale)
        return "\(when) · \(what)"
    }

    /// "Today 14:02", "Yesterday 09:00", else the abbreviated date and time.
    static func when(
        _ date: Date,
        now: Date,
        locale: Locale = .current,
        calendar: Calendar = .autoupdatingCurrent
    ) -> String {
        let shipped = LocalizedCopy.shippedLocale(for: locale)
        var timeStyle = Date.FormatStyle(date: .omitted, time: .shortened).locale(shipped)
        timeStyle.calendar = calendar
        timeStyle.timeZone = calendar.timeZone
        let time: String = date.formatted(timeStyle)
        if calendar.isDate(date, inSameDayAs: now) {
            return LocalizedStringResource.accountWarmUpsToday(time).string(in: locale)
        }
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)
        if let yesterday, calendar.isDate(date, inSameDayAs: yesterday) {
            return LocalizedStringResource.accountWarmUpsYesterday(time).string(in: locale)
        }
        var fullStyle = Date.FormatStyle(date: .abbreviated, time: .shortened).locale(shipped)
        fullStyle.calendar = calendar
        fullStyle.timeZone = calendar.timeZone
        return date.formatted(fullStyle)
    }

    static func what(_ outcome: WarmUpOutcome, locale: Locale = .current) -> String {
        let resource: LocalizedStringResource
        switch outcome.kind {
        case .sent:
            resource = .accountWarmUpsSent
        case .rejected:
            if let status = outcome.httpStatus {
                resource = .accountWarmUpsRefused(status)
            } else {
                resource = .accountWarmUpsFailed
            }
        case .rejectedInStream:
            let type = outcome.streamErrorType ?? .unknown
            resource = .accountWarmUpsRefusedInReply(type.rawValue)
        case .skipped:
            resource = skipped(outcome.skipReason)
        case .failed:
            resource = failed(outcome.errorKind)
        }
        return resource.string(in: locale)
    }

    private static func skipped(_ reason: WarmUpOutcome.SkipReason?) -> LocalizedStringResource {
        switch reason {
        case .weeklyLimitSpent: .accountWarmUpsHeldWeeklyLimit
        case .organizationUnknown: .accountWarmUpsSkippedWorkspaceUnknown
        case .warmUpTurnedOff: .accountWarmUpsSkippedTurnedOff
        case nil: .accountWarmUpsFailed
        }
    }

    private static func failed(_ kind: WarmUpOutcome.ErrorKind?) -> LocalizedStringResource {
        switch kind {
        case .transport: .accountWarmUpsUnreachable
        case .timedOut: .accountWarmUpsTimedOut
        case .organizationNotFound: .accountWarmUpsWorkspaceNotFound
        case .modelNotFound: .accountWarmUpsModelNotFound
        case .authentication, .http, .stream, .other, nil: .accountWarmUpsFailed
        }
    }
}
