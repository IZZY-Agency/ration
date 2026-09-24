import AppKit

/// Opens System Settings › Notifications at Ration's entry.
///
/// `NSWorkspace.open` returns true whenever System Settings accepts the
/// scheme — it cannot tell whether the `?id=` was honoured, so an ignored id
/// simply lands on the Notifications list. The fallback only covers the
/// scheme itself being refused.
enum NotificationSettingsOpener {
    @MainActor
    static func open() {
        let bundleID = Bundle.main.bundleIdentifier ?? "agency.izzy.ration"
        if !NSWorkspace.shared.open(NotificationAccess.settingsURL(bundleID: bundleID)) {
            NSWorkspace.shared.open(NotificationAccess.fallbackSettingsURL)
        }
    }
}
