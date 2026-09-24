import XCTest
@testable import Ration

/// When macOS blocks Ration's notifications while alerts are on, the UI must
/// say so — without claiming alerts are off (the drop still works).
final class NotificationAccessTests: XCTestCase {
    func testProblemPerPermissionWhileAlertsOn() {
        XCTAssertEqual(NotificationAccess.problem(alertsEnabled: true, permission: .denied), .blocked)
        XCTAssertEqual(NotificationAccess.problem(alertsEnabled: true, permission: .notDetermined), .needsPermission)
        XCTAssertNil(NotificationAccess.problem(alertsEnabled: true, permission: .allowed))
    }

    /// Alerts off: nothing to notify, so no surface nags.
    func testNoProblemWhileAlertsOff() {
        for permission: NotificationPermission? in [.denied, .notDetermined, .allowed, nil] {
            XCTAssertNil(NotificationAccess.problem(alertsEnabled: false, permission: permission))
        }
    }

    /// Unknown (not yet read — launch, or a startup pass that returned early)
    /// is no problem: no banner may flash or stick on a guess.
    func testUnknownPermissionIsNoProblem() {
        XCTAssertNil(NotificationAccess.problem(alertsEnabled: true, permission: nil))
    }

    /// Never asked: the copy must offer to ask, not send the user to a
    /// System Settings list Ration isn't in yet.
    func testNeedsPermissionCopy() {
        let problem = NotificationAccess.Problem.needsPermission
        XCTAssertEqual(problem.popoverBanner, "Ration hasn't asked for notification permission yet.")
        XCTAssertEqual(problem.generalNote, "Ration hasn't asked for notification permission yet.")
        XCTAssertEqual(problem.alertsPaneNote, "Allow notifications so alerts can notify — the drop still works.")
        XCTAssertEqual(NotificationAccess.allowTitle, "Allow Notifications")
    }

    func testBlockedCopyUnchanged() {
        let problem = NotificationAccess.Problem.blocked
        XCTAssertEqual(problem.popoverBanner, NotificationAccess.popoverBanner)
        XCTAssertEqual(problem.generalNote, "Allow notifications for Ration in System Settings › Notifications.")
        XCTAssertEqual(problem.alertsPaneNote, NotificationAccess.alertsPaneNote)
    }

    func testPopoverBannerCopyDoesNotClaimAlertsAreOff() {
        XCTAssertEqual(
            NotificationAccess.popoverBanner,
            "Alerts can't notify — macOS is blocking Ration's notifications"
        )
    }

    func testAlertsPaneNoteMentionsTheDropStillWorks() {
        XCTAssertEqual(
            NotificationAccess.alertsPaneNote,
            "Notifications are blocked by macOS — the drop still works."
        )
    }

    func testSettingsURLTargetsRationsNotificationPane() {
        XCTAssertEqual(
            NotificationAccess.settingsURL(bundleID: "agency.izzy.ration").absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=agency.izzy.ration"
        )
        XCTAssertEqual(
            NotificationAccess.fallbackSettingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        )
    }
}
