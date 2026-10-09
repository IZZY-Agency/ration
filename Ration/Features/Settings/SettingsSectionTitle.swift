import Foundation

/// Every fixed Settings section header, in one place so the capitalisation
/// convention is enforced by a test: Title Case, like macOS Settings. The
/// account and warm-up panes used to shout (IDENTITY, QUIET HOURS) next to
/// panes in Title Case (General, Claude). French and Ukrainian use sentence
/// case, as their macOS settings do.
///
/// Each header resolves in the running language; the `(locale:)` forms pin one.
enum SettingsSectionTitle {
    static var accounts: String { accounts(locale: .current) }
    static var general: String { general(locale: .current) }
    static var menuBar: String { menuBar(locale: .current) }
    static var ringBar: String { ringBar(locale: .current) }
    static var notifications: String { notifications(locale: .current) }
    static var popover: String { popover(locale: .current) }
    static var gauges: String { gauges(locale: .current) }
    static var rings: String { rings(locale: .current) }
    static var features: String { features(locale: .current) }
    static var identity: String { identity(locale: .current) }
    static var automation: String { automation(locale: .current) }
    static var resets: String { resets(locale: .current) }
    static var billing: String { billing(locale: .current) }
    static var session: String { session(locale: .current) }
    static var quietHours: String { quietHours(locale: .current) }
    static var holidays: String { holidays(locale: .current) }
    static var cursorSpend: String { cursorSpend(locale: .current) }
    static var planValue: String { planValue(locale: .current) }
    static var usageCredits: String { usageCredits(locale: .current) }

    static var all: [String] { all(locale: .current) }

    static func all(locale: Locale) -> [String] {
        [
            accounts(locale: locale), general(locale: locale), notifications(locale: locale),
            popover(locale: locale), gauges(locale: locale), menuBar(locale: locale),
            ringBar(locale: locale), rings(locale: locale), features(locale: locale), identity(locale: locale), automation(locale: locale),
            resets(locale: locale), billing(locale: locale), session(locale: locale),
            quietHours(locale: locale), holidays(locale: locale), cursorSpend(locale: locale),
            planValue(locale: locale), usageCredits(locale: locale),
        ]
    }

    static func accounts(locale: Locale) -> String { LocalizedStringResource.settingsSectionAccounts.string(in: locale) }
    static func general(locale: Locale) -> String { LocalizedStringResource.settingsSectionGeneral.string(in: locale) }
    static func menuBar(locale: Locale) -> String { LocalizedStringResource.settingsSectionMenuBar.string(in: locale) }
    static func ringBar(locale: Locale) -> String { LocalizedStringResource.settingsSectionRingBar.string(in: locale) }
    static func notifications(locale: Locale) -> String { LocalizedStringResource.settingsSectionNotifications.string(in: locale) }
    static func popover(locale: Locale) -> String { LocalizedStringResource.settingsSectionPopover.string(in: locale) }
    static func gauges(locale: Locale) -> String { LocalizedStringResource.settingsSectionGauges.string(in: locale) }
    static func rings(locale: Locale) -> String { LocalizedStringResource.settingsSectionRings.string(in: locale) }
    static func features(locale: Locale) -> String { LocalizedStringResource.settingsSectionFeatures.string(in: locale) }
    static func identity(locale: Locale) -> String { LocalizedStringResource.settingsSectionIdentity.string(in: locale) }
    static func automation(locale: Locale) -> String { LocalizedStringResource.settingsSectionAutomation.string(in: locale) }
    static func resets(locale: Locale) -> String { LocalizedStringResource.settingsSectionResets.string(in: locale) }
    static func billing(locale: Locale) -> String { LocalizedStringResource.settingsSectionBilling.string(in: locale) }
    static func session(locale: Locale) -> String { LocalizedStringResource.settingsSectionSession.string(in: locale) }
    static func quietHours(locale: Locale) -> String { LocalizedStringResource.settingsSectionQuietHours.string(in: locale) }
    static func holidays(locale: Locale) -> String { LocalizedStringResource.settingsSectionHolidays.string(in: locale) }
    static func cursorSpend(locale: Locale) -> String { LocalizedStringResource.settingsSectionCursorSpend.string(in: locale) }
    static func planValue(locale: Locale) -> String { LocalizedStringResource.settingsSectionPlanValue.string(in: locale) }
    static func usageCredits(locale: Locale) -> String { LocalizedStringResource.settingsSectionUsageCredits.string(in: locale) }
}
