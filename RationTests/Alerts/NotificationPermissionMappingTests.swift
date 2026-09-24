import UserNotifications
import XCTest
@testable import Ration

/// The live scheduler's status mapping. `.notDetermined` must stay apart
/// from `.denied`: the UI offers to ask for one and System Settings for the
/// other, and only a grant may open the posting gate.
final class NotificationPermissionMappingTests: XCTestCase {
    func testGrantsMapToAllowed() {
        XCTAssertEqual(NotificationPermission(UNAuthorizationStatus.authorized), .allowed)
        XCTAssertEqual(NotificationPermission(UNAuthorizationStatus.provisional), .allowed)
    }

    func testRefusalMapsToDenied() {
        XCTAssertEqual(NotificationPermission(UNAuthorizationStatus.denied), .denied)
    }

    func testNeverAskedMapsToNotDetermined() {
        XCTAssertEqual(NotificationPermission(UNAuthorizationStatus.notDetermined), .notDetermined)
    }
}
