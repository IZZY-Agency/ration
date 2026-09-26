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

/// A selection asked for from OUTSIDE the Settings window — the popover
/// header's STALE click opens Settings on the account to fix. The window's
/// own sidebar clicks never go through here.
///
/// One per Settings window, owned by whoever opened it. Each request carries
/// a serial, so the window applies every request exactly once: a re-render or
/// a re-subscription replays the latest value, and must not yank the user
/// back after they moved to another pane.
@MainActor
final class SettingsSelectionRequest: ObservableObject {
    struct Request: Equatable, Sendable {
        let serial: Int
        let selection: SettingsSelection
    }

    @Published private(set) var latest: Request?

    /// `initial` nil → nothing requested, and the window opens on its default
    /// pane (General).
    init(initial: SettingsSelection? = nil) {
        if let initial {
            latest = Request(serial: 1, selection: initial)
        }
    }

    func request(_ selection: SettingsSelection) {
        let serial: Int = (latest?.serial ?? 0) + 1
        latest = Request(serial: serial, selection: selection)
    }

    /// What the window should select for `request`, or nil when there is
    /// nothing new to apply (no request, or one already applied). An account
    /// that no longer exists falls back like any other stale selection.
    static func resolve(
        _ request: Request?,
        appliedSerial: Int,
        accounts: [AccountRecord]
    ) -> (selection: SettingsSelection, serial: Int)? {
        guard let request, request.serial > appliedSerial else { return nil }
        let selection = SettingsSelection.normalized(request.selection, accounts: accounts)
        return (selection, request.serial)
    }
}
