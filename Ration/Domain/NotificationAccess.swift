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

    // Copy, in the running language; each has a `(locale:)` form for a
    // pinned language.
    static var popoverBanner: String { popoverBanner(locale: .current) }
    static var alertsPaneNote: String { alertsPaneNote(locale: .current) }
    static var generalBlockedNote: String { generalBlockedNote(locale: .current) }
    static var openSettingsTitle: String { openSettingsTitle(locale: .current) }

    static var needsPermissionBanner: String { needsPermissionBanner(locale: .current) }
    static var needsPermissionAlertsNote: String { needsPermissionAlertsNote(locale: .current) }
    static var allowTitle: String { allowTitle(locale: .current) }
    static var allowHelp: String { allowHelp(locale: .current) }

    static func popoverBanner(locale: Locale) -> String {
        LocalizedStringResource.notificationAccessPopoverBanner.string(in: locale)
    }

    static func alertsPaneNote(locale: Locale) -> String {
        LocalizedStringResource.notificationAccessAlertsPaneNote.string(in: locale)
    }

    static func generalBlockedNote(locale: Locale) -> String {
        LocalizedStringResource.notificationAccessGeneralBlockedNote.string(in: locale)
    }

    static func openSettingsTitle(locale: Locale) -> String {
        LocalizedStringResource.notificationAccessOpenSettingsTitle.string(in: locale)
    }

    static func needsPermissionBanner(locale: Locale) -> String {
        LocalizedStringResource.notificationAccessNeedsPermissionBanner.string(in: locale)
    }

    static func needsPermissionAlertsNote(locale: Locale) -> String {
        LocalizedStringResource.notificationAccessNeedsPermissionAlertsNote.string(in: locale)
    }

    static func allowTitle(locale: Locale) -> String {
        LocalizedStringResource.notificationAccessAllowTitle.string(in: locale)
    }

    static func allowHelp(locale: Locale) -> String {
        LocalizedStringResource.notificationAccessAllowHelp.string(in: locale)
    }

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
    var popoverBanner: String { popoverBanner(locale: .current) }
    var generalNote: String { generalNote(locale: .current) }
    var alertsPaneNote: String { alertsPaneNote(locale: .current) }

    func popoverBanner(locale: Locale) -> String {
        switch self {
        case .blocked: NotificationAccess.popoverBanner(locale: locale)
        case .needsPermission: NotificationAccess.needsPermissionBanner(locale: locale)
        }
    }

    func generalNote(locale: Locale) -> String {
        switch self {
        case .blocked: NotificationAccess.generalBlockedNote(locale: locale)
        case .needsPermission: NotificationAccess.needsPermissionBanner(locale: locale)
        }
    }

    func alertsPaneNote(locale: Locale) -> String {
        switch self {
        case .blocked: NotificationAccess.alertsPaneNote(locale: locale)
        case .needsPermission: NotificationAccess.needsPermissionAlertsNote(locale: locale)
        }
    }
}
