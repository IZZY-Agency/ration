import Carbon.HIToolbox
import XCTest
@testable import Ration

@MainActor
final class GlobalHotKeyControllerTests: XCTestCase {
    func testDefaultsAreOptionCommandU() {
        XCTAssertEqual(GlobalHotKeyController.defaultKeyCode, UInt32(kVK_ANSI_U))
        XCTAssertEqual(
            GlobalHotKeyController.defaultModifiers,
            UInt32(optionKey | cmdKey)
        )
    }

    func testRegisterForwardsConfiguredKeyAndModifiers() {
        let registrar = HotKeyRegistrarSpy()
        let controller = GlobalHotKeyController(registrar: registrar) {}

        XCTAssertTrue(controller.register())

        XCTAssertTrue(controller.isRegistered)
        XCTAssertEqual(registrar.registeredKeyCode, UInt32(kVK_ANSI_U))
        XCTAssertEqual(registrar.registeredModifiers, UInt32(optionKey | cmdKey))
        XCTAssertEqual(registrar.registerCallCount, 1)
    }

    func testRegisterIsIdempotent() {
        let registrar = HotKeyRegistrarSpy()
        let controller = GlobalHotKeyController(registrar: registrar) {}

        XCTAssertTrue(controller.register())
        XCTAssertTrue(controller.register())

        XCTAssertEqual(registrar.registerCallCount, 1)
    }

    func testFiringHotKeyInvokesOnFire() {
        let registrar = HotKeyRegistrarSpy()
        var fireCount = 0
        let controller = GlobalHotKeyController(registrar: registrar) {
            fireCount += 1
        }
        controller.register()

        registrar.fire()
        registrar.fire()

        XCTAssertEqual(fireCount, 2)
    }

    func testUnregisterStopsForwardingAndClearsState() {
        let registrar = HotKeyRegistrarSpy()
        var fireCount = 0
        let controller = GlobalHotKeyController(registrar: registrar) {
            fireCount += 1
        }
        controller.register()

        controller.unregister()

        XCTAssertFalse(controller.isRegistered)
        XCTAssertEqual(registrar.unregisterCallCount, 1)
        registrar.fire()
        XCTAssertEqual(fireCount, 0)
    }

    func testFailedRegistrationLeavesControllerUnregistered() {
        let registrar = HotKeyRegistrarSpy()
        registrar.shouldSucceed = false
        let controller = GlobalHotKeyController(registrar: registrar) {}

        XCTAssertFalse(controller.register())
        XCTAssertFalse(controller.isRegistered)
    }
}

@MainActor
final class HotKeyRegistrarSpy: GlobalHotKeyRegistering {
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var registeredKeyCode: UInt32?
    private(set) var registeredModifiers: UInt32?
    var shouldSucceed = true
    private var onFire: (@MainActor () -> Void)?

    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        onFire: @escaping @MainActor () -> Void
    ) -> Bool {
        registerCallCount += 1
        guard shouldSucceed else { return false }
        registeredKeyCode = keyCode
        registeredModifiers = modifiers
        self.onFire = onFire
        return true
    }

    func unregister() {
        unregisterCallCount += 1
        onFire = nil
    }

    func fire() {
        onFire?()
    }
}
