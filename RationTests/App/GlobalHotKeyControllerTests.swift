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

/// Several `CarbonHotKeyRegistrar`s live at once while the popover is open
/// (⌥⌘U plus the popover keys), each with its own Carbon handler on the same
/// application target. A handler must act only on ITS hotkey and pass every
/// other one down the chain — otherwise the newest handler swallows them all.
/// Driven by in-process Carbon events sent to our own application target (no
/// keystrokes reach any other app).
@MainActor
final class CarbonHotKeyRegistrarDispatchTests: XCTestCase {
    private func sendHotKeyPressed(_ id: EventHotKeyID) -> OSStatus {
        var event: EventRef?
        XCTAssertEqual(
            CreateEvent(
                nil,
                OSType(kEventClassKeyboard),
                UInt32(kEventHotKeyPressed),
                GetCurrentEventTime(),
                EventAttributes(kEventAttributeNone),
                &event
            ),
            noErr
        )
        guard let event else { return OSStatus(eventInternalErr) }
        defer { ReleaseEvent(event) }
        var hotKeyID = id
        SetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size,
            &hotKeyID
        )
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }

    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
    }

    func testEachHandlerFiresOnlyForItsOwnHotKey() throws {
        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let first = CarbonHotKeyRegistrar()
        let second = CarbonHotKeyRegistrar()
        var fired: [String] = []
        XCTAssertTrue(first.register(keyCode: UInt32(kVK_F19), modifiers: modifiers) { fired.append("first") })
        XCTAssertTrue(second.register(keyCode: UInt32(kVK_F18), modifiers: modifiers) { fired.append("second") })
        defer {
            first.unregister()
            second.unregister()
        }
        let firstID = try XCTUnwrap(first.registeredHotKeyID)
        let secondID = try XCTUnwrap(second.registeredHotKeyID)
        XCTAssertNotEqual(firstID.id, secondID.id)

        // `first` was installed first, so `second`'s handler sees it first.
        XCTAssertEqual(sendHotKeyPressed(firstID), noErr)
        drainMainQueue()
        XCTAssertEqual(fired, ["first"])

        XCTAssertEqual(sendHotKeyPressed(secondID), noErr)
        drainMainQueue()
        XCTAssertEqual(fired, ["first", "second"])

        // Per-hotkey unregister: `second` goes, `first` still answers.
        second.unregister()
        XCTAssertEqual(sendHotKeyPressed(secondID), OSStatus(eventNotHandledErr))
        XCTAssertEqual(sendHotKeyPressed(firstID), noErr)
        drainMainQueue()
        XCTAssertEqual(fired, ["first", "second", "first"])
    }

    /// A press is delivered to the main queue; one that is already queued
    /// when the popover closes (or the app stops) must not run afterwards.
    func testAPressQueuedBeforeUnregisterNeverRuns() throws {
        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let registrar = CarbonHotKeyRegistrar()
        var fired = 0
        XCTAssertTrue(registrar.register(keyCode: UInt32(kVK_F17), modifiers: modifiers) { fired += 1 })
        let id = try XCTUnwrap(registrar.registeredHotKeyID)

        XCTAssertEqual(sendHotKeyPressed(id), noErr)
        registrar.unregister()
        drainMainQueue()
        XCTAssertEqual(fired, 0)
    }

    /// Close → reopen re-registers on the same registrar before the queued
    /// press runs; a per-registrar "is registered" flag would be true again,
    /// so the stale press must be tied to ITS registration.
    func testAPressQueuedBeforeCloseNeverRunsAfterReopen() throws {
        let modifiers = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let registrar = CarbonHotKeyRegistrar()
        var fired: [String] = []
        XCTAssertTrue(registrar.register(keyCode: UInt32(kVK_F17), modifiers: modifiers) { fired.append("old") })
        let id = try XCTUnwrap(registrar.registeredHotKeyID)
        defer { registrar.unregister() }

        XCTAssertEqual(sendHotKeyPressed(id), noErr)
        registrar.unregister()
        XCTAssertTrue(registrar.register(keyCode: UInt32(kVK_F17), modifiers: modifiers) { fired.append("new") })
        drainMainQueue()
        XCTAssertEqual(fired, [])
    }
}

/// The popover's ⌘ keys follow the CHARACTER, as Cocoa key equivalents do —
/// on AZERTY ⌘Q is the key labelled Q, which sits where ANSI has A.
@MainActor
final class ShortcutKeyCodeResolverTests: XCTestCase {
    private let ansi: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "a", UInt16(kVK_ANSI_Q): "q", UInt16(kVK_ANSI_R): "r",
        UInt16(kVK_ANSI_D): "d", UInt16(kVK_ANSI_Comma): ",", UInt16(kVK_ANSI_M): "m",
        UInt16(kVK_ANSI_KeypadDecimal): ","
    ]
    private let azerty: [UInt16: String] = [
        UInt16(kVK_ANSI_A): "q", UInt16(kVK_ANSI_Q): "a", UInt16(kVK_ANSI_R): "r",
        UInt16(kVK_ANSI_D): "d", UInt16(kVK_ANSI_M): ",", UInt16(kVK_ANSI_Comma): ";",
        UInt16(kVK_ANSI_KeypadDecimal): ","
    ]

    func testANSIResolvesToTheANSIKeys() {
        let translate: (UInt16) -> String? = { self.ansi[$0] }
        XCTAssertEqual(ShortcutKeyCodeResolver.keyCode(for: "q", fallback: UInt32(kVK_ANSI_Q), translate: translate), UInt32(kVK_ANSI_Q))
        XCTAssertEqual(ShortcutKeyCodeResolver.keyCode(for: ",", fallback: UInt32(kVK_ANSI_Comma), translate: translate), UInt32(kVK_ANSI_Comma))
    }

    func testAZERTYResolvesByCharacterAndSkipsTheKeypad() {
        let translate: (UInt16) -> String? = { self.azerty[$0] }
        XCTAssertEqual(ShortcutKeyCodeResolver.keyCode(for: "q", fallback: UInt32(kVK_ANSI_Q), translate: translate), UInt32(kVK_ANSI_A))
        XCTAssertEqual(ShortcutKeyCodeResolver.keyCode(for: "r", fallback: UInt32(kVK_ANSI_R), translate: translate), UInt32(kVK_ANSI_R))
        XCTAssertEqual(ShortcutKeyCodeResolver.keyCode(for: ",", fallback: UInt32(kVK_ANSI_Comma), translate: translate), UInt32(kVK_ANSI_M))
    }

    func testNoLayoutFallsBackToANSI() {
        XCTAssertEqual(ShortcutKeyCodeResolver.keyCode(for: "d", fallback: UInt32(kVK_ANSI_D), translate: { _ in nil }), UInt32(kVK_ANSI_D))
    }

    func testTheLiveLayoutResolvesEveryPopoverKey() {
        // Whatever this Mac's layout is, each key must resolve to SOME key
        // that types its character (or the ANSI fallback) — never crash.
        for shortcut in PopoverShortcut.allCases {
            XCTAssertLessThan(ShortcutKeyCodeResolver.liveKeyCode(for: shortcut), 128)
        }
    }
}

@MainActor
final class HotKeyRegistrarSpy: GlobalHotKeyRegistering {
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    private(set) var registeredKeyCode: UInt32?
    private(set) var registeredModifiers: UInt32?
    private(set) var attemptedKeyCode: UInt32?
    private(set) var registeredExclusive: Bool?
    var shouldSucceed = true
    /// Key codes this spy refuses, as Carbon does for a combination another
    /// app already owns.
    var refusedKeyCodes: Set<UInt32> = []
    private var onFire: (@MainActor () -> Void)?

    var isRegistered: Bool { onFire != nil }

    @discardableResult
    func register(
        keyCode: UInt32,
        modifiers: UInt32,
        exclusive: Bool,
        onFire: @escaping @MainActor () -> Void
    ) -> Bool {
        registerCallCount += 1
        attemptedKeyCode = keyCode
        guard shouldSucceed, !refusedKeyCodes.contains(keyCode) else { return false }
        registeredExclusive = exclusive
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
