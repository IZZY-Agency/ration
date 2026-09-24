/// Every fixed Settings section header, in one place so the capitalisation
/// convention is enforced by a test: Title Case, like macOS Settings. The
/// account and warm-up panes used to shout (IDENTITY, QUIET HOURS) next to
/// panes in Title Case (General, Claude).
enum SettingsSectionTitle {
    static let accounts = "Accounts"
    static let general = "General"
    static let menuBar = "Menu Bar"
    static let features = "Features"
    static let identity = "Identity"
    static let automation = "Automation"
    static let resets = "Resets"
    static let billing = "Billing"
    static let session = "Session"
    static let quietHours = "Quiet Hours"
    static let holidays = "Holidays"
    static let cursorSpend = "Cursor Spend"

    static let all = [
        accounts, general, menuBar, features, identity, automation, resets, billing,
        session, quietHours, holidays, cursorSpend,
    ]
}
