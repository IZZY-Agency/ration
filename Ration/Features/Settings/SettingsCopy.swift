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

    static func resetCreditUsability(_ usable: Bool, locale: Locale = .current) -> String {
        usable
            ? LocalizedStringResource.accountResetCreditUsableNow.string(in: locale)
            : LocalizedStringResource.accountResetCreditNotUsableYet.string(in: locale)
    }
}
