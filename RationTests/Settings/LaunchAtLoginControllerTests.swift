import XCTest
@testable import Ration

@MainActor
final class LaunchAtLoginControllerTests: XCTestCase {
    func testEnablingRegistersAndPublishesEnabledState() async {
        let service = LaunchAtLoginServiceSpy(status: .notRegistered)
        service.statusAfterRegister = .enabled
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(controller.state, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
    }

    func testDisablingUnregistersAndPublishesDisabledState() async {
        let service = LaunchAtLoginServiceSpy(status: .enabled)
        service.statusAfterUnregister = .notRegistered
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(false)

        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(controller.state, .disabled)
        XCTAssertFalse(controller.isEnabled)
    }

    func testRequiresApprovalRemainsEnabledWithExplanation() {
        let service = LaunchAtLoginServiceSpy(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertEqual(controller.state, .requiresApproval)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNotNil(controller.explanation)
    }

    func testRequiresApprovalExplanationUsesRationName() {
        let service = LaunchAtLoginServiceSpy(status: .requiresApproval)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertEqual(
            controller.explanation,
            "Allow Ration in System Settings → General → Login Items."
        )
    }

    func testNotFoundIsTheNeverRegisteredStateAndReportsDisabled() {
        // `.notFound` is what SMAppService reports while Background Task
        // Management has no record of the app at all — i.e. `register()` has
        // never been called (backgroundtaskmanagementd logs it as "record not
        // found", verified on macOS 27 with a Developer ID signed build). It is
        // the pre-registration state, not a verdict that registration is
        // impossible, so the toggle must be offered, off.
        let service = LaunchAtLoginServiceSpy(status: .notFound)
        let controller = LaunchAtLoginController(service: service)

        XCTAssertEqual(controller.state, .disabled)
        XCTAssertNil(controller.explanation)
        XCTAssertFalse(controller.isEnabled)
    }

    func testEnablingFromNotFoundRegistersAndPublishesEnabledState() async {
        let service = LaunchAtLoginServiceSpy(status: .notFound)
        service.statusAfterRegister = .enabled
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(true)

        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(controller.state, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNil(controller.errorMessage)
    }

    func testRegistrationFailureFromNotFoundKeepsToggleOffWithError() async {
        // A registration that genuinely cannot succeed (whatever the reason)
        // speaks through `errorMessage`; the row is never hidden for it.
        let service = LaunchAtLoginServiceSpy(status: .notFound)
        service.registerError = TestFailure.expected
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(true)

        XCTAssertEqual(controller.state, .disabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testRegistrationErrorSurfacesWithoutOptimisticStateChange() async {
        let service = LaunchAtLoginServiceSpy(status: .notRegistered)
        service.registerError = TestFailure.expected
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(true)

        XCTAssertEqual(controller.state, .disabled)
        XCTAssertFalse(controller.isEnabled)
        XCTAssertNotNil(controller.errorMessage)
    }

    func testUnregistrationErrorKeepsEnabledState() async {
        let service = LaunchAtLoginServiceSpy(status: .enabled)
        service.unregisterError = TestFailure.expected
        let controller = LaunchAtLoginController(service: service)

        await controller.setEnabled(false)

        XCTAssertEqual(controller.state, .enabled)
        XCTAssertTrue(controller.isEnabled)
        XCTAssertNotNil(controller.errorMessage)
    }
}

@MainActor
private final class LaunchAtLoginServiceSpy: LaunchAtLoginService {
    var status: LaunchAtLoginServiceStatus
    var statusAfterRegister: LaunchAtLoginServiceStatus?
    var statusAfterUnregister: LaunchAtLoginServiceStatus?
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0

    init(status: LaunchAtLoginServiceStatus) {
        self.status = status
    }

    func register() async throws {
        registerCallCount += 1
        if let registerError {
            throw registerError
        }
        if let statusAfterRegister {
            status = statusAfterRegister
        }
    }

    func unregister() async throws {
        unregisterCallCount += 1
        if let unregisterError {
            throw unregisterError
        }
        if let statusAfterUnregister {
            status = statusAfterUnregister
        }
    }

    func openSystemSettings() {}
}

private enum TestFailure: Error {
    case expected
}
