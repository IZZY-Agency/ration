import Foundation

/// The choices in the popover's Keep awake menu, in menu order. Every timed
/// choice ends on its own; `untilOff` is the one open-ended override.
enum KeepAwakeDuration: String, CaseIterable, Identifiable, Sendable {
    case minutes30
    case hours1
    case hours2
    case hours4
    case hours8
    case untilOff

    var id: String { rawValue }

    /// The override's length; nil = until the user stops it.
    var seconds: TimeInterval? {
        switch self {
        case .minutes30: 30 * 60
        case .hours1: 3_600
        case .hours2: 2 * 3_600
        case .hours4: 4 * 3_600
        case .hours8: 8 * 3_600
        case .untilOff: nil
        }
    }

    func title(locale: Locale = .current) -> String {
        let resource: LocalizedStringResource = switch self {
        case .minutes30: .keepAwakeDurationMinutes30
        case .hours1: .keepAwakeDurationHours1
        case .hours2: .keepAwakeDurationHours2
        case .hours4: .keepAwakeDurationHours4
        case .hours8: .keepAwakeDurationHours8
        case .untilOff: .keepAwakeDurationUntilOff
        }
        return resource.string(in: locale)
    }
}

/// The popover's keep-awake wording, in one place so the footer button, its
/// menu and the banner never disagree. Pure; every line is a catalog entry
/// resolved in `locale` (the running language by default).
enum KeepAwakeCopy {
    /// The footer button's name (tooltip and VoiceOver).
    static func buttonLabel(locale: Locale = .current) -> String {
        LocalizedStringResource.keepAwakeButton.string(in: locale)
    }

    /// The menu item that ends the override.
    static func stopTitle(locale: Locale = .current) -> String {
        LocalizedStringResource.keepAwakeStop.string(in: locale)
    }

    /// The footer eye's tooltip while the Keep awake switch is off in
    /// Settings (the button is disabled then).
    static func offInSettings(locale: Locale = .current) -> String {
        LocalizedStringResource.keepAwakeOffInSettings.string(in: locale)
    }

    /// "1h 12m left" — the same compact countdown the cards use for resets.
    static func timeLeft(until: Date, now: Date, locale: Locale = .current) -> String {
        let countdown: String = UsageFormatters.remainingUntilResetLeadingUnitOrFull(until, relativeTo: now, locale: locale)
        return LocalizedStringResource.keepAwakeTimeLeft(countdown).string(in: locale)
    }

    /// The banner line for a live hold; nil when nothing is held. The end of
    /// a timed override is a clock time in `timeZone`.
    static func banner(
        _ status: KeepAwakeStatus,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String? {
        switch status {
        case .off:
            return nil
        case .automatic:
            return LocalizedStringResource.keepAwakeBannerAutomatic.string(in: locale)
        case .manual(until: nil):
            return LocalizedStringResource.keepAwakeBannerManualIndefinite.string(in: locale)
        case let .manual(until: .some(until)):
            let style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone)
            return LocalizedStringResource.keepAwakeBannerManualUntil(until.formatted(style)).string(in: locale)
        }
    }
}

private extension UsageFormatters {
    /// `remainingUntilReset` floored to "0m" instead of "now" when the end
    /// is under a minute away: a menu line says how much is left, not that
    /// something is due.
    static func remainingUntilResetLeadingUnitOrFull(_ end: Date, relativeTo now: Date, locale: Locale) -> String {
        guard end.timeIntervalSince(now) >= 60 else {
            return remainingUntilResetLeadingUnit(end, relativeTo: now, locale: locale)
        }
        return remainingUntilReset(end, relativeTo: now, locale: locale)
    }
}
