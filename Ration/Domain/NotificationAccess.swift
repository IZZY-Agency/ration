import Foundation

/// What macOS says about Ration's notifications. `notDetermined` is its own
/// state, not a refusal: an app appears in System Settings › Notifications
/// only once it has asked, so sending a never-asked user there strands them.
enum NotificationPermission: Equatable, Sendable {
    case allowed
    case denied
    case notDetermined
}

/// Why alerts can't notify while usage alerts are on, and the copy and action
/// every surface uses to say so.
///
/// Only notifications are affected: the attention drop needs no
/// authorization, so no copy here may claim alerts are off.
enum NotificationAccess {
    enum Problem: Equatable {
        /// macOS refused (the user said no, or turned it off in System
        /// Settings). Only System Settings can undo it.
        case blocked
        /// Ration has never asked. Asking — on an explicit click — is the fix.
        case needsPermission
    }

    /// `permission == nil` means not read yet (launch, or a startup pass that
    /// returned early): guessing would flash — or strand — a banner that is
    /// not true, so unknown is never a problem.
    static func problem(alertsEnabled: Bool, permission: NotificationPermission?) -> Problem? {
        guard alertsEnabled else { return nil }
        switch permission {
        case .denied: return .blocked
        case .notDetermined: return .needsPermission
        case .allowed, nil: return nil
        }
    }

    static let popoverBanner = "Alerts can't notify — macOS is blocking Ration's notifications"
    static let alertsPaneNote = "Notifications are blocked by macOS — the drop still works."
    static let generalBlockedNote = "Allow notifications for Ration in System Settings › Notifications."
    static let openSettingsTitle = "Open Notification Settings"

    static let needsPermissionBanner = "Ration hasn't asked for notification permission yet."
    static let needsPermissionAlertsNote = "Allow notifications so alerts can notify — the drop still works."
    static let allowTitle = "Allow Notifications"
    static let allowHelp = "Ask macOS to let Ration send notifications"

    /// System Settings › Notifications, scrolled to this app's entry.
    static func settingsURL(bundleID: String) -> URL {
        var components = URLComponents()
        components.scheme = "x-apple.systempreferences"
        components.path = "com.apple.Notifications-Settings.extension"
        components.queryItems = [URLQueryItem(name: "id", value: bundleID)]
        return components.url ?? fallbackSettingsURL
    }

    /// The Notifications pane itself, for when the per-app URL is refused.
    static let fallbackSettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    )!
}

extension NotificationAccess.Problem {
    var popoverBanner: String {
        switch self {
        case .blocked: NotificationAccess.popoverBanner
        case .needsPermission: NotificationAccess.needsPermissionBanner
        }
    }

    var generalNote: String {
        switch self {
        case .blocked: NotificationAccess.generalBlockedNote
        case .needsPermission: NotificationAccess.needsPermissionBanner
        }
    }

    var alertsPaneNote: String {
        switch self {
        case .blocked: NotificationAccess.alertsPaneNote
        case .needsPermission: NotificationAccess.needsPermissionAlertsNote
        }
    }
}
