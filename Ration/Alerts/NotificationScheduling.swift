import Foundation
@preconcurrency import UserNotifications

/// Thin seam over `UNUserNotificationCenter` so the alert pipeline can be
/// driven with an injected stub in tests, and the real OS notification center
/// is only ever touched by `UserNotificationScheduler`.
protocol NotificationScheduling: Sendable {
    func requestAuthorization() async -> Bool
    /// The OS-level authorization status, queried fresh (not cached) — used
    /// on `AppModel.load()` (relaunch) since the user may have granted or
    /// revoked notification permission in System Settings since the app last
    /// called `requestAuthorization`.
    func authorizationStatus() async -> Bool
    func post(id: String, title: String, body: String) async
}

/// Live implementation wrapping `UNUserNotificationCenter.current()`.
/// Best-effort throughout: both operations swallow framework errors rather
/// than throwing, since a failed notification should never interrupt the
/// alert pipeline that triggered it.
final class UserNotificationScheduler: NotificationScheduling {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func authorizationStatus() async -> Bool {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
    }

    func post(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        try? await center.add(request)
    }
}
