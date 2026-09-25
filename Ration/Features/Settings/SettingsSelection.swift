import Foundation

/// Which item the Settings split view has selected.
enum SettingsSelection: Hashable {
    case account(UUID)
    case general
    case warmUp
    case alerts

    /// The item to select when the window opens, and after the selected
    /// account is removed: always the General pane.
    static let defaultSelection: SettingsSelection = .general

    /// The selection to keep after the account list changes. Non-account items
    /// are always preserved; an account item survives only while its account
    /// exists. Exhaustive on purpose: a new case must not silently fall through
    /// to the default and yank the user to another pane when an account is
    /// added or removed.
    static func normalized(
        _ selection: SettingsSelection?,
        accounts: [AccountRecord]
    ) -> SettingsSelection {
        switch selection {
        case .general:
            return .general
        case .warmUp:
            return .warmUp
        case .alerts:
            return .alerts
        case let .account(id) where accounts.contains(where: { $0.id == id }):
            return .account(id)
        case .account, nil:
            return defaultSelection
        }
    }
}
