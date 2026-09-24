import AppKit
import Carbon.HIToolbox
import WebKit
import XCTest
@testable import Ration

@MainActor
final class RationApplicationDelegateTests: XCTestCase {
    func testStatusItemButtonTogglesPopoverPresenter() throws {
        let harness = makeHarness()
        defer { harness.stop() }

        let popover = PopoverPresenterSpy()
        let hotKeyRegistrar = HotKeyRegistrarSpy()
        let controller = MenuBarController(
            model: harness.model,
            launchAtLogin: harness.launchAtLogin,
            popover: popover,
            hotKeyRegistrar: hotKeyRegistrar,
            makePopoverHotKeyRegistrar: HotKeyRegistrarFactorySpy().make
        )
        controller.start()
        defer { controller.stop() }
        XCTAssertEqual(hotKeyRegistrar.registeredKeyCode, UInt32(kVK_ANSI_U))
        let button = try XCTUnwrap(controller.statusItem?.button)

        XCTAssertTrue(button.target === controller)
        XCTAssertEqual(
            button.action.map(NSStringFromSelector),
            "togglePopover:"
        )

        let action = try XCTUnwrap(button.action)
        XCTAssertTrue(
            NSApplication.shared.sendAction(
                action,
                to: button.target,
                from: button
            )
        )
        XCTAssertTrue(popover.isShown)
        XCTAssertTrue(
            NSApplication.shared.sendAction(
                action,
                to: button.target,
                from: button
            )
        )
        XCTAssertFalse(popover.isShown)
    }

    // MARK: - Popover shortcuts as temporary global hotkeys
    //
    // An LSUIElement app is never active, so the popover never becomes key and
    // its SwiftUI `.keyboardShortcut`s never see a key event. While the popover
    // is shown, ⌘R / ⌘, / ⌘Q (and ⌘D while the drop is up) are Carbon hotkeys.

    private func makeShortcutController(
        harness: DelegateHarness,
        factory: HotKeyRegistrarFactorySpy,
        refreshes: @escaping () -> Void = {},
        quits: @escaping () -> Void = {},
        popover: PopoverPresenterSpy = PopoverPresenterSpy(),
        statusItemIsAnchored: @escaping () -> Bool = { true },
        keyCode: @escaping @MainActor (PopoverShortcut) -> UInt32 = { $0.ansiKeyCode }
    ) -> (MenuBarController, PopoverPresenterSpy, HotKeyRegistrarSpy) {
        let optionCommandU = HotKeyRegistrarSpy()
        let controller = MenuBarController(
            model: harness.model,
            launchAtLogin: harness.launchAtLogin,
            popover: popover,
            hotKeyRegistrar: optionCommandU,
            makePopoverHotKeyRegistrar: factory.make,
            refreshAll: refreshes,
            terminateApp: quits,
            statusItemIsAnchored: statusItemIsAnchored,
            popoverKeyCode: keyCode
        )
        controller.start()
        return (controller, popover, optionCommandU)
    }

    private func clickStatusItem(_ controller: MenuBarController) throws {
        let button = try XCTUnwrap(controller.statusItem?.button)
        XCTAssertTrue(
            NSApplication.shared.sendAction(try XCTUnwrap(button.action), to: button.target, from: button)
        )
    }

    func testShowingThePopoverRegistersCommandRCommaQ() throws {
        let harness = makeHarness()
        defer { harness.stop() }
        let factory = HotKeyRegistrarFactorySpy()
        let (controller, _, optionCommandU) = makeShortcutController(harness: harness, factory: factory)
        defer { controller.stop() }

        XCTAssertTrue(factory.active.isEmpty, "nothing is claimed while the popover is closed")
        try clickStatusItem(controller)

        XCTAssertEqual(
            Set(factory.active.map(\.registeredKeyCode)),
            [UInt32(kVK_ANSI_R), UInt32(kVK_ANSI_Comma), UInt32(kVK_ANSI_Q)]
        )
        XCTAssertTrue(factory.active.allSatisfy { $0.registeredModifiers == UInt32(cmdKey) })
        XCTAssertTrue(factory.active.allSatisfy { $0.registeredExclusive == true }, "conflicts must be detected")
        XCTAssertEqual(optionCommandU.registeredExclusive, false, "⌥⌘U keeps its shared registration")
        XCTAssertEqual(optionCommandU.registerCallCount, 1)
        XCTAssertEqual(optionCommandU.unregisterCallCount, 0)
    }

    func testCommandDIsClaimedOnlyWhileTheDropIsShowing() throws {
        let harness = makeHarness()
        defer { harness.stop() }
        let factory = HotKeyRegistrarFactorySpy()
        let (controller, _, _) = makeShortcutController(harness: harness, factory: factory)
        defer { controller.stop() }

        try clickStatusItem(controller)
        XCTAssertNil(factory.active(keyCode: kVK_ANSI_D))

        controller.attentionPresence.set(true)
        XCTAssertNotNil(factory.active(keyCode: kVK_ANSI_D), "the drop appearing while open claims ⌘D")

        controller.attentionPresence.set(false)
        XCTAssertNil(factory.active(keyCode: kVK_ANSI_D), "and its leaving releases it")
        XCTAssertEqual(factory.active.count, 3)
    }

    func testDropAlreadyShowingClaimsCommandDOnPresent() throws {
        let harness = makeHarness()
        defer { harness.stop() }
        let factory = HotKeyRegistrarFactorySpy()
        let (controller, _, _) = makeShortcutController(harness: harness, factory: factory)
        defer { controller.stop() }

        controller.attentionPresence.set(true)
        XCTAssertTrue(factory.active.isEmpty, "the drop alone claims nothing")
        try clickStatusItem(controller)
        XCTAssertEqual(factory.active.count, 4)
    }

    func testEveryClosePathReleasesEveryPopoverHotKey() throws {
        let harness = makeHarness()
        defer { harness.stop() }
        let factory = HotKeyRegistrarFactorySpy()
        let (controller, popover, optionCommandU) = makeShortcutController(harness: harness, factory: factory)
        defer { controller.stop() }

        // Toggle via the status item.
        try clickStatusItem(controller)
        controller.attentionPresence.set(true)
        XCTAssertEqual(factory.active.count, 4)
        try clickStatusItem(controller)
        XCTAssertTrue(factory.active.isEmpty, "toggle closed")

        // Transient click-away / Esc: AppKit closes the popover itself.
        try clickStatusItem(controller)
        XCTAssertEqual(factory.active.count, 4)
        popover.performClose(nil)
        XCTAssertTrue(factory.active.isEmpty, "click-away / Esc")

        // Opening a window from the popover (⌘, fired as a hotkey).
        try clickStatusItem(controller)
        factory.active(keyCode: kVK_ANSI_Comma)?.fire()
        XCTAssertTrue(controller.hasSettingsWindow, "⌘, runs the Settings button's path")
        XCTAssertFalse(popover.isShown)
        XCTAssertTrue(factory.active.isEmpty, "opening a window")

        // Reopening claims fresh registrations; nothing leaks across.
        try clickStatusItem(controller)
        XCTAssertEqual(factory.active.count, 4)
        XCTAssertEqual(factory.made.count, 16, "four presentations, each registers its own set")
        XCTAssertEqual(optionCommandU.unregisterCallCount, 0, "⌥⌘U untouched throughout")
    }

    func testStopReleasesPopoverHotKeysEvenIfNoCloseCallbackArrives() throws {
        let harness = makeHarness()
        defer { harness.stop() }
        let factory = HotKeyRegistrarFactorySpy()
        let (controller, popover, optionCommandU) = makeShortcutController(harness: harness, factory: factory)

        try clickStatusItem(controller)
        popover.sendsDidClose = false
        controller.stop()

        XCTAssertTrue(factory.active.isEmpty)
        XCTAssertTrue(factory.made.allSatisfy { $0.unregisterCallCount == 1 }, "released exactly once")
        XCTAssertEqual(optionCommandU.unregisterCallCount, 1)
    }

    func testHotKeysRunTheButtonActions() throws {
        let harness = makeHarness()
        defer { harness.stop() }
        let factory = HotKeyRegistrarFactorySpy()
        var refreshes = 0
        var quits = 0
        let (controller, _, _) = makeShortcutController(
            harness: harness,
            factory: factory,
            refreshes: { refreshes += 1 },
            quits: { quits += 1 }
        )
        defer { controller.stop() }

        try clickStatusItem(controller)
        factory.active(keyCode: kVK_ANSI_R)?.fire()
        XCTAssertEqual(refreshes, 1)
        XCTAssertEqual(quits, 0)
        factory.active(keyCode: kVK_ANSI_Q)?.fire()
        XCTAssertEqual(quits, 1)
        XCTAssertEqual(refreshes, 1)
    }

    func testAShowThatNeverHappensClaimsNothing() throws {
        let harness = makeHarness()
        defer { harness.stop() }
        let factory = HotKeyRegistrarFactorySpy()
        let popover = PopoverPresenterSpy()
        popover.showSucceeds = false
        let (controller, _, _) = makeShortcutController(harness: harness, factory: factory, popover: popover)
        defer { controller.stop() }

        try clickStatusItem(controller)
        XCTAssertFalse(popover.isShown)
        XCTAssertTrue(factory.made.isEmpty, "no popover, no didClose — so nothing may be claimed")
    }

    func testKeysAreClaimedOnDidShowNotOnTheShowRequest() throws {
        let harness = makeHarness()
        defer { harness.stop() }
        let factory = HotKeyRegistrarFactorySpy()
        let popover = PopoverPresenterSpy()
        popover.defersNotifications = true
        let (controller, _, _) = makeShortcutController(harness: harness, factory: factory, popover: popover)
        defer { controller.stop() }

        try clickStatusItem(controller)
        XCTAssertTrue(factory.made.isEmpty)
        popover.deliverPendingNotifications()
        XCTAssertEqual(factory.active.count, 3)

        // Closed before its didShow arrives: the late didShow claims nothing.
        popover.performClose(nil)
        popover.deliverPendingNotifications()
        XCTAssertTrue(factory.active.isEmpty)
        // Closed mid-animation: only the late didShow arrives (no didClose
        // would follow to release anything it claimed).
        try clickStatusItem(controller)
        popover.sendsDidClose = false
        popover.performClose(nil)
        popover.deliverPendingNotifications()
        XCTAssertTrue(factory.active.isEmpty, "a didShow landing after the close claims nothing")
    }

    func testALateDidCloseDoesNotReleaseTheNextPresentationsKeys() throws {
        let harness = makeHarness()
        defer { harness.stop() }
        let factory = HotKeyRegistrarFactorySpy()
        let popover = PopoverPresenterSpy()
        let (controller, _, _) = makeShortcutController(harness: harness, factory: factory, popover: popover)
        defer { controller.stop() }

        try clickStatusItem(controller)
        popover.defersNotifications = true
        popover.performClose(nil)          // didClose still in flight
        popover.defersNotifications = false
        try clickStatusItem(controller)    // reopened, keys claimed
        XCTAssertEqual(factory.active.count, 3)
        popover.deliverPendingNotifications()
        XCTAssertEqual(factory.active.count, 3, "the stale didClose belongs to the previous presentation")
    }

    func testADropRowWithNoStatusItemOnScreenOpensTheWindowInstead() throws {
        let harness = makeHarness()
        defer { harness.stop() }
        let factory = HotKeyRegistrarFactorySpy()
        let (controller, popover, _) = makeShortcutController(
            harness: harness, factory: factory, statusItemIsAnchored: { false }
        )
        defer { controller.stop() }

        controller.openPopoverFromDropForTesting()
        XCTAssertFalse(popover.isShown)
        XCTAssertTrue(controller.hasFallbackWindow)
        XCTAssertTrue(factory.made.isEmpty)
    }

    func testKeyCodesFollowTheLayoutAtEachPresentation() throws {
        let harness = makeHarness()
        defer { harness.stop() }
        let factory = HotKeyRegistrarFactorySpy()
        var azerty = false
        let (controller, popover, _) = makeShortcutController(
            harness: harness,
            factory: factory,
            keyCode: { shortcut in
                azerty && shortcut == .quit ? UInt32(kVK_ANSI_A) : shortcut.ansiKeyCode
            }
        )
        defer { controller.stop() }

        try clickStatusItem(controller)
        XCTAssertNotNil(factory.active(keyCode: kVK_ANSI_Q))
        popover.performClose(nil)

        azerty = true
        try clickStatusItem(controller)
        XCTAssertNil(factory.active(keyCode: kVK_ANSI_Q))
        XCTAssertNotNil(factory.active(keyCode: kVK_ANSI_A), "⌘Q is the key that types q")
    }

    func testOneFailedRegistrationDoesNotBlockTheOthers() throws {
        let harness = makeHarness()
        defer { harness.stop() }
        let factory = HotKeyRegistrarFactorySpy()
        factory.failingKeyCodes = [UInt32(kVK_ANSI_R)]
        let (controller, _, optionCommandU) = makeShortcutController(harness: harness, factory: factory)
        defer { controller.stop() }

        try clickStatusItem(controller)
        XCTAssertEqual(
            Set(factory.active.map(\.registeredKeyCode)),
            [UInt32(kVK_ANSI_Comma), UInt32(kVK_ANSI_Q)]
        )
        // A drop change mid-presentation must not retry the refused key.
        controller.attentionPresence.set(true)
        XCTAssertEqual(factory.made.filter { $0.attemptedKeyCode == UInt32(kVK_ANSI_R) }.count, 1)
        XCTAssertTrue(optionCommandU.isRegistered)
    }

    /// On macOS 26 the popover's chrome is translucent Liquid Glass
    /// (`NSGlassView`). Its appearance already follows the app, but the glass
    /// still takes its colour from what is behind it — the dark menu bar — so
    /// with the app in Light the chevron drew dark grey while the body looked
    /// right only because SwiftUI paints `Theme.ink` over it. Full-size
    /// content lets that ink extend into the chevron too.
    func testPopoverContentExtendsIntoTheChevron() throws {
        let harness = makeHarness()
        defer { harness.stop() }

        let popover = PopoverPresenterSpy()
        let controller = MenuBarController(
            model: harness.model,
            launchAtLogin: harness.launchAtLogin,
            popover: popover,
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        controller.start()
        defer { controller.stop() }

        XCTAssertTrue(popover.hasFullSizeContent)
    }

    /// The popover must follow the APP's appearance, never the menu bar's.
    /// With `appearance = nil` a shown popover inherits its positioning view
    /// — the status button, i.e. the bar's vibrant appearance — so in System
    /// mode on a dark menu bar with Light macOS it came up dark. Every show
    /// and every apply must hand it a concrete aqua/darkAqua.
    func testPopoverAppearanceFollowsTheAppNotTheMenuBar() throws {
        let harness = makeHarness()
        defer { harness.stop() }
        let savedAppAppearance = NSApp.appearance
        defer { NSApp.appearance = savedAppAppearance }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PopoverAppearance-\(UUID())"))
        let appearance = AppearanceController(defaults: defaults)
        let popover = PopoverPresenterSpy()
        var shownWith: [NSAppearance.Name?] = []
        popover.onShow = { [unowned popover] in shownWith.append(popover.appearance?.name) }
        let controller = MenuBarController(
            model: harness.model,
            launchAtLogin: harness.launchAtLogin,
            appearance: appearance,
            popover: popover,
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        controller.start()
        defer { controller.stop() }
        let button = try XCTUnwrap(controller.statusItem?.button)
        let action = try XCTUnwrap(button.action)
        func toggleOpen() {
            XCTAssertTrue(NSApplication.shared.sendAction(action, to: button.target, from: button))
            XCTAssertTrue(popover.isShown)
            popover.close()
        }
        func systemName() -> NSAppearance.Name? {
            NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua])
        }

        // System, straight from start(): concrete, and the OS's own choice.
        XCTAssertNotNil(popover.appearance)
        XCTAssertEqual(popover.appearance?.name, systemName())
        toggleOpen()
        XCTAssertEqual(shownWith.last, systemName())

        appearance.setMode(.light)
        XCTAssertEqual(popover.appearance?.name, .aqua)
        toggleOpen()
        XCTAssertEqual(shownWith.last, .aqua)

        appearance.setMode(.dark)
        XCTAssertEqual(popover.appearance?.name, .darkAqua)
        toggleOpen()
        XCTAssertEqual(shownWith.last, .darkAqua)

        appearance.setMode(.system)
        XCTAssertNotNil(popover.appearance, "System must not fall back to the menu bar's appearance")
        XCTAssertEqual(popover.appearance?.name, systemName())
        toggleOpen()
        XCTAssertEqual(shownWith.last, systemName())
    }

    /// The same on a REAL popover shown from the real status item, with the
    /// app forced to Light: the hosting view must cover the whole popover
    /// frame (chevron included), and resolve to Aqua.
    func testRealPopoverPaintsItsChevronInTheAppAppearance() throws {
        let harness = makeHarness()
        defer { harness.stop() }
        let savedAppAppearance = NSApp.appearance
        defer { NSApp.appearance = savedAppAppearance }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "PopoverChevron-\(UUID())"))
        defaults.set(AppearanceMode.light.rawValue, forKey: AppearanceController.defaultsKey)
        let popover = NSPopover()
        let controller = MenuBarController(
            model: harness.model,
            launchAtLogin: harness.launchAtLogin,
            appearance: AppearanceController(defaults: defaults),
            popover: popover,
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        controller.start()
        defer {
            popover.close()
            controller.stop()
        }
        let button = try XCTUnwrap(controller.statusItem?.button)
        // A fresh status item has no menu-bar frame for a moment; showing a
        // popover from it before then silently does nothing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let action = try XCTUnwrap(button.action)
        XCTAssertTrue(NSApplication.shared.sendAction(action, to: button.target, from: button))

        let content = try XCTUnwrap(popover.contentViewController?.view)
        guard let window = content.window, let frameView = content.superview else {
            throw XCTSkip("popover did not come on screen in this session")
        }
        XCTAssertEqual(window.effectiveAppearance.name, .aqua)
        XCTAssertEqual(content.effectiveAppearance.name, .aqua)
        XCTAssertEqual(content.frame, frameView.bounds, "content must reach into the chevron")
    }

    func testReopenShowsFallbackWindowAndSuppressesDefaultHandling() throws {
        let harness = makeHarness()
        defer { harness.stop() }

        let shouldHandle = harness.delegate.applicationShouldHandleReopen(
            NSApplication.shared,
            hasVisibleWindows: false
        )

        XCTAssertEqual(shouldHandle, false)
        let window = try XCTUnwrap(
            NSApplication.shared.windows.first {
                $0.title == "Ration" && $0.isVisible
            }
        )
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        window.close()
    }

    func testToggleHidesOnlyWhenWindowIsKeyOfActiveApp() {
        // Hide only when visible + app active + window is key.
        XCTAssertTrue(
            MenuBarController.shouldHideOnToggle(
                isVisible: true, appIsActive: true, windowIsKey: true
            )
        )
        // Buried behind another app (app not active) → summon, don't hide.
        XCTAssertFalse(
            MenuBarController.shouldHideOnToggle(
                isVisible: true, appIsActive: false, windowIsKey: true
            )
        )
        // Visible but not key → summon and focus.
        XCTAssertFalse(
            MenuBarController.shouldHideOnToggle(
                isVisible: true, appIsActive: true, windowIsKey: false
            )
        )
        // Hidden → show.
        XCTAssertFalse(
            MenuBarController.shouldHideOnToggle(
                isVisible: false, appIsActive: true, windowIsKey: true
            )
        )
    }

    /// Two Claude accounts, A then B, take turns being "most active" between
    /// opens (via `recordActivity`, seeded directly into the model's real
    /// history store — no mocked capture policy). If the pin were read
    /// *after* `show(...)` returns, deleted entirely, or captured only once
    /// and reused, at least one of the two `onShow` reads below would not
    /// equal the account that was actually active at that exact moment.
    func testPopoverCapturesPinAtShowTimeAndRecapturesOnReopen() async throws {
        let now = Date.now
        let accountA = makeAccount(.claude, label: "A", order: 0)
        let accountB = makeAccount(.claude, label: "B", order: 1)
        let model = try await makeModel(seedAccounts: [accountA, accountB])
        defer { model.stop() }
        // Only A has activity yet — A is "most active" for the first open.
        recordActivity(for: accountA, in: model.history, endingAt: now.addingTimeInterval(-180))

        let popover = PopoverPresenterSpy()
        let popoverPin = AccountPinSnapshot()
        let controller = MenuBarController(
            model: model,
            launchAtLogin: LaunchAtLoginController(),
            popover: popover,
            hotKeyRegistrar: HotKeyRegistrarSpy(),
            popoverPin: popoverPin
        )
        controller.start()
        defer { controller.stop() }

        // Read INSIDE the closure, synchronously as `show(...)` runs — this is
        // the only read that can tell "captured before this show" apart from
        // "captured after" or "never captured".
        var pinsSeenAtShow: [UUID?] = []
        popover.onShow = {
            pinsSeenAtShow.append(popoverPin.orderingPinByProvider[.claude])
        }

        let button = try XCTUnwrap(controller.statusItem?.button)
        _ = button.target?.perform(button.action, with: button)   // open — sees A

        // B overtakes A as the most-recently-used Claude account before reopen.
        recordActivity(for: accountB, in: model.history, endingAt: now.addingTimeInterval(-60))

        _ = button.target?.perform(button.action, with: button)   // close
        _ = button.target?.perform(button.action, with: button)   // reopen — must see B

        XCTAssertEqual(
            pinsSeenAtShow,
            [accountA.id, accountB.id],
            "each show must read a pin captured for THAT show, not a stale or absent value"
        )
    }

    func testPresentingPopoverDoesNotMutateFallbackPin() async throws {
        let now = Date.now
        let account = makeAccount(.claude, label: "A", order: 0)
        let model = try await makeModel(seedAccounts: [account])
        defer { model.stop() }
        recordActivity(for: account, in: model.history, endingAt: now.addingTimeInterval(-60))

        let popoverPin = AccountPinSnapshot()
        let fallbackPin = AccountPinSnapshot()
        let controller = MenuBarController(
            model: model,
            launchAtLogin: LaunchAtLoginController(),
            popover: PopoverPresenterSpy(),
            hotKeyRegistrar: HotKeyRegistrarSpy(),
            popoverPin: popoverPin,
            fallbackPin: fallbackPin
        )
        controller.start()
        defer { controller.stop() }

        let button = try XCTUnwrap(controller.statusItem?.button)
        _ = button.target?.perform(button.action, with: button)   // open popover only

        XCTAssertEqual(
            popoverPin.orderingPinByProvider[.claude], account.id,
            "opening the popover must capture the currently-active account"
        )
        XCTAssertTrue(
            fallbackPin.orderingPinByProvider.isEmpty,
            "opening the popover must never mutate the fallback window's own snapshot"
        )
    }

    /// Drives the real `showFallbackWindow()` (not the pure `shouldCapture`
    /// policy in isolation) through all three transitions the design names:
    /// new-window creation captures, a hidden window coming back captures
    /// again, and a plain re-focus of an already-visible window does not.
    /// Which Claude account is "most active" is flipped between each call via
    /// `recordActivity` on the real history store, so a stale/frozen pin is
    /// distinguishable from a correctly-recaptured one at every step.
    ///
    /// Also injects `popoverPin` (rather than letting it default) and asserts
    /// it stays empty throughout — the "and vice versa" half of
    /// `testPresentingPopoverDoesNotMutateFallbackPin`'s cross-surface
    /// isolation guarantee: presenting the fallback window must never mutate
    /// the popover's own snapshot either.
    func testFallbackWindowCapturesOnCreationAndHiddenToVisibleButNotOnVisibleRefocus() async throws {
        let now = Date.now
        let accountA = makeAccount(.claude, label: "A", order: 0)
        let accountB = makeAccount(.claude, label: "B", order: 1)
        let model = try await makeModel(seedAccounts: [accountA, accountB])
        defer { model.stop() }
        recordActivity(for: accountA, in: model.history, endingAt: now.addingTimeInterval(-240))

        let popoverPin = AccountPinSnapshot()
        let fallbackPin = AccountPinSnapshot()
        let controller = MenuBarController(
            model: model,
            launchAtLogin: LaunchAtLoginController(),
            popover: PopoverPresenterSpy(),
            hotKeyRegistrar: HotKeyRegistrarSpy(),
            popoverPin: popoverPin,
            fallbackPin: fallbackPin
        )
        controller.start()
        defer { controller.stop() }

        // 1) New window: must capture. A is active.
        controller.showFallbackWindow()
        XCTAssertEqual(
            fallbackPin.orderingPinByProvider[.claude], accountA.id,
            "creating the fallback window must capture"
        )

        let window = try XCTUnwrap(
            NSApplication.shared.windows.first { $0.title == "Ration" && $0.isVisible }
        )

        // 2) B overtakes A while the window is hidden; showing it again must
        // recapture and reflect B.
        window.orderOut(nil)
        XCTAssertFalse(window.isVisible)
        recordActivity(for: accountB, in: model.history, endingAt: now.addingTimeInterval(-120))

        controller.showFallbackWindow()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(
            fallbackPin.orderingPinByProvider[.claude], accountB.id,
            "a hidden window coming back must recapture"
        )

        // 3) A overtakes B again, but the window is already visible — a plain
        // re-focus must NOT move cards under the user's cursor, so the pin
        // must stay on B even though the model now says A is more active.
        recordActivity(for: accountA, in: model.history, endingAt: now.addingTimeInterval(-10))
        controller.showFallbackWindow()
        XCTAssertEqual(
            fallbackPin.orderingPinByProvider[.claude], accountB.id,
            "re-focusing an already-visible window must not recapture"
        )

        XCTAssertTrue(
            popoverPin.orderingPinByProvider.isEmpty,
            "presenting the fallback window must never mutate the popover's own snapshot"
        )
    }

    func testOnboardingRequestBeforeControllerExistsLatchesUntilConfigured() async throws {
        // The real ordering: `AppModel.start()` finishes loading settings (and
        // so can answer `shouldPresentOnboarding`) before
        // `applicationDidFinishLaunching` has built the menu bar.
        let harness = DelegateHarness()
        defer { harness.stop() }
        try await harness.model.load(startBackgroundRefresh: false)
        harness.delegate.model = harness.model

        harness.delegate.presentOnboardingIfNeeded()

        XCTAssertTrue(harness.delegate.isOnboardingOwed)
        XCTAssertNil(harness.delegate.menuBarController)

        harness.delegate.configure(
            model: harness.model,
            launchAtLogin: harness.launchAtLogin,
            hotKeyRegistrar: harness.hotKeyRegistrar
        )
        harness.delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        let controller = try XCTUnwrap(harness.delegate.menuBarController)
        XCTAssertTrue(
            controller.hasOnboardingWindow,
            "the controller arriving must actually present the wizard"
        )
        // The owed flag is cleared by DISMISSAL, not by display — that is what
        // makes a manually dismissed wizard consume it too.
        XCTAssertTrue(harness.delegate.isOnboardingOwed)
        await harness.model.markOnboardingCompleted()
        XCTAssertFalse(harness.delegate.isOnboardingOwed)
        controller.closeOnboardingForTesting()
    }

    func testOnboardingIsRefusedUntilStartupInputsHaveLoaded() throws {
        // `start()` swallows a thrown `load()` into
        // `errorMessage`, so an existing user whose accounts.json was briefly
        // unreadable presents as empty-with-clean-settings — indistinguishable
        // from a fresh install unless the model refuses to answer at all.
        let harness = DelegateHarness()
        defer { harness.stop() }

        XCTAssertFalse(
            harness.model.isOnboardingOwed,
            "an unloaded account store must never read as a fresh install"
        )

        harness.delegate.model = harness.model
        harness.delegate.presentOnboardingIfNeeded()

        XCTAssertFalse(harness.delegate.isOnboardingOwed)
    }

    func testOnboardingIsRefusedOnceTerminationHasBegun() async throws {
        let harness = makeHarness()
        defer { harness.stop() }
        try await harness.model.load(startBackgroundRefresh: false)
        let controller = try XCTUnwrap(harness.delegate.menuBarController)

        // Positive control FIRST: without this, the assertion below passes for
        // any reason at all.
        harness.delegate.presentOnboardingIfNeeded()
        XCTAssertTrue(
            controller.hasOnboardingWindow,
            "precondition: this model/controller pair does present the wizard"
        )
        controller.closeOnboardingForTesting()
        XCTAssertFalse(controller.hasOnboardingWindow)

        _ = harness.delegate.applicationShouldTerminate(NSApplication.shared)
        harness.delegate.presentOnboardingIfNeeded()

        XCTAssertFalse(
            controller.hasOnboardingWindow,
            "a quit in progress must not be interrupted by a welcome window"
        )
    }

    func testOwedOnboardingIsDeliveredWithoutReDerivingTheDecision() async throws {
        // Delivery must trust the latch, never re-sample
        // `shouldPresentOnboarding`. Account creation publishes the account
        // BEFORE its snapshot is saved and rolls it back if that fails, so a
        // sample taken at delivery time can read a transient `1` for a sign-in
        // that ultimately failed — and silently discard a genuine first run.
        //
        // The account transient needs a data-layer mutation seam to stage, so
        // this drives the same invariant through the other input the predicate
        // reads: if delivery re-derived the decision from the model at all,
        // this would not present.
        let harness = makeHarness()
        defer { harness.stop() }
        try await harness.model.load(startBackgroundRefresh: false)
        let controller = try XCTUnwrap(harness.delegate.menuBarController)

        // Startup finishes while a quit is in progress: the wizard is owed.
        _ = harness.delegate.applicationShouldTerminate(NSApplication.shared)
        harness.delegate.presentOnboardingIfNeeded()
        XCTAssertTrue(harness.delegate.isOnboardingOwed)
        XCTAssertFalse(controller.hasOnboardingWindow)

        // An account appears and the persisted flag flips — neither is allowed
        // to cancel the owed presentation, because both are exactly what goes
        // transiently wrong mid-commit. Only an actual dismissal may.
        try await harness.model.settings.setHasCompletedOnboarding(true)
        XCTAssertTrue(
            harness.model.isOnboardingOwed,
            "the decision is captured at load; later store state must not revoke it"
        )

        harness.delegate.resolveTerminationForTesting(canTerminate: false)

        XCTAssertTrue(
            controller.hasOnboardingWindow,
            "delivery must not re-derive; re-deriving loses real first runs to a transient account"
        )
    }

    func testManuallyDismissedWizardConsumesAnOwedAutoPresentation() async throws {
        // auto-onboarding becomes owed during a `.terminateLater`
        // quit; the user opens Setup Guide from Settings and closes it; the quit
        // aborts. Delivery must NOT reopen a wizard they already dismissed.
        let harness = makeHarness()
        defer { harness.stop() }
        try await harness.model.load(startBackgroundRefresh: false)
        let controller = try XCTUnwrap(harness.delegate.menuBarController)

        _ = harness.delegate.applicationShouldTerminate(NSApplication.shared)
        harness.delegate.presentOnboardingIfNeeded()
        XCTAssertTrue(harness.delegate.isOnboardingOwed)

        // Manual open, then dismiss — the same path Settings → Setup Guide uses.
        controller.showOnboarding()
        XCTAssertTrue(controller.hasOnboardingWindow)
        await harness.model.markOnboardingCompleted()
        controller.closeOnboardingForTesting()
        XCTAssertFalse(controller.hasOnboardingWindow)

        harness.delegate.resolveTerminationForTesting(canTerminate: false)

        XCTAssertFalse(
            controller.hasOnboardingWindow,
            "a dismissed wizard must not reappear when the quit is abandoned"
        )
    }

    func testOverlappingQuitsDoNotPresentWhileOneIsStillPending() async throws {
        let harness = makeHarness()
        defer { harness.stop() }
        try await harness.model.load(startBackgroundRefresh: false)
        let controller = try XCTUnwrap(harness.delegate.menuBarController)

        // Two quits in flight; one is abandoned.
        _ = harness.delegate.applicationShouldTerminate(NSApplication.shared)
        _ = harness.delegate.applicationShouldTerminate(NSApplication.shared)
        harness.delegate.presentOnboardingIfNeeded()
        harness.delegate.resolveTerminationForTesting(canTerminate: false)

        XCTAssertFalse(
            controller.hasOnboardingWindow,
            "one aborted quit must not declare the app safe while another decision is pending"
        )

        // The second one is abandoned too — now it is safe.
        harness.delegate.resolveTerminationForTesting(canTerminate: false)

        XCTAssertTrue(controller.hasOnboardingWindow)
    }

    func testOnboardingRequestIsNotLatchedOnceCompleted() async throws {
        let harness = DelegateHarness()
        defer { harness.stop() }
        harness.delegate.model = harness.model
        try await harness.model.load(startBackgroundRefresh: false)
        await harness.model.markOnboardingCompleted()

        harness.delegate.presentOnboardingIfNeeded()

        XCTAssertFalse(harness.delegate.isOnboardingOwed)
    }

    func testOnboardingLatchIsConsumedOnlyOnce() async throws {
        let harness = DelegateHarness()
        defer { harness.stop() }
        try await harness.model.load(startBackgroundRefresh: false)
        harness.delegate.model = harness.model
        harness.delegate.presentOnboardingIfNeeded()

        harness.delegate.configure(
            model: harness.model,
            launchAtLogin: harness.launchAtLogin,
            hotKeyRegistrar: harness.hotKeyRegistrar
        )
        harness.delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        let controller = try XCTUnwrap(harness.delegate.menuBarController)
        XCTAssertTrue(controller.hasOnboardingWindow)

        // Dismiss, then let every delivery trigger fire again. None may reopen.
        await harness.model.markOnboardingCompleted()
        controller.closeOnboardingForTesting()
        XCTAssertFalse(controller.hasOnboardingWindow)
        XCTAssertFalse(harness.delegate.isOnboardingOwed)

        harness.delegate.configure(
            model: harness.model,
            launchAtLogin: harness.launchAtLogin,
            hotKeyRegistrar: harness.hotKeyRegistrar
        )
        harness.delegate.presentOnboardingIfNeeded()
        harness.delegate.resolveTerminationForTesting(canTerminate: false)

        XCTAssertFalse(harness.delegate.isOnboardingOwed)
        XCTAssertFalse(
            controller.hasOnboardingWindow,
            "shown-once: no delivery trigger may reopen a dismissed wizard"
        )
    }

    private func makeHarness() -> DelegateHarness {
        let harness = DelegateHarness()
        harness.delegate.configure(
            model: harness.model,
            launchAtLogin: harness.launchAtLogin,
            hotKeyRegistrar: harness.hotKeyRegistrar
        )
        harness.delegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )
        return harness
    }
}

@MainActor
private final class PopoverPresenterSpy: PopoverPresenting {
    private(set) var isShown = false
    var behavior: NSPopover.Behavior = .applicationDefined
    var contentViewController: NSViewController?
    var appearance: NSAppearance?
    var hasFullSizeContent = false
    weak var delegate: (any NSPopoverDelegate)?
    var onShow: (() -> Void)?
    /// Whether closing reports `popoverDidClose`, as `NSPopover` does.
    var sendsDidClose = true
    /// False: `show` does nothing, as when AppKit cannot present.
    var showSucceeds = true
    /// True: didShow / didClose are held until `deliverPendingNotifications`,
    /// as AppKit delivers them after the animation.
    var defersNotifications = false
    private var pending: [() -> Void] = []

    func deliverPendingNotifications() {
        let queued = pending
        pending = []
        queued.forEach { $0() }
    }

    private func notify(_ body: @escaping () -> Void) {
        if defersNotifications { pending.append(body) } else { body() }
    }

    func show(
        relativeTo positioningRect: NSRect,
        of positioningView: NSView,
        preferredEdge: NSRectEdge
    ) {
        guard showSucceeds else { return }
        isShown = true
        onShow?()
        notify { [weak self] in
            self?.delegate?.popoverDidShow?(Notification(name: NSPopover.didShowNotification))
        }
    }

    func performClose(_ sender: Any?) {
        close()
    }

    func close() {
        guard isShown else { return }
        isShown = false
        if sendsDidClose {
            notify { [weak self] in
                self?.delegate?.popoverDidClose?(Notification(name: NSPopover.didCloseNotification))
            }
        }
    }
}

/// Hands out a fresh `HotKeyRegistrarSpy` per popover hotkey, like the
/// production factory hands out a `CarbonHotKeyRegistrar` per key.
@MainActor
private final class HotKeyRegistrarFactorySpy {
    private(set) var made: [HotKeyRegistrarSpy] = []
    var failingKeyCodes: Set<UInt32> = []

    func make() -> any GlobalHotKeyRegistering {
        let spy = HotKeyRegistrarSpy()
        spy.refusedKeyCodes = failingKeyCodes
        made.append(spy)
        return spy
    }

    var active: [HotKeyRegistrarSpy] { made.filter(\.isRegistered) }

    func active(keyCode: Int) -> HotKeyRegistrarSpy? {
        active.first { $0.registeredKeyCode == UInt32(keyCode) }
    }
}

/// Builds an `AccountRecord` for the capture tests. `createdAt` is fixed and
/// irrelevant here — only `displayOrder` (tie-break) and `provider` matter to
/// `ActiveUsageDetector`.
@MainActor
private func makeAccount(_ provider: Provider, label: String, order: Int) -> AccountRecord {
    AccountRecord(
        id: UUID(), provider: provider, label: label,
        webProfileID: UUID(), displayOrder: order,
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

/// A real `AppModel`, constructed via its designated initializer (not
/// `.live()`) so `seedAccounts` are present in `model.accounts` immediately —
/// no sign-in flow, no `load()`, no disk round-trip required. Callers then use
/// `model.history` (a real, public `UsageHistoryStore`) to control which
/// account is "active" and when, via `recordActivity` below.
@MainActor
private func makeModel(seedAccounts: [AccountRecord]) async throws -> AppModel {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let accountStore = AccountStore(
        fileURL: directory.appending(path: "accounts.json")
    )
    for account in seedAccounts {
        try await accountStore.add(account)
    }
    return AppModel(
        accountStore: accountStore,
        snapshotStore: UsageSnapshotStore(
            fileURL: directory.appending(path: "snapshots.json")
        ),
        pendingProfileDeletionStore: PendingProfileDeletionStore(
            fileURL: directory.appending(path: "pending-profile-deletions.json")
        ),
        historyStore: UsageHistoryStore(
            rootDirectory: directory.appending(path: "history", directoryHint: .isDirectory)
        ),
        appSettings: AppSettings(
            fileURL: directory.appending(path: "app-settings.json")
        ),
        alertStateStore: AlertStateStore(
            fileURL: directory.appending(path: "alert-state.json")
        ),
        profileManager: WebProfileManagingStub(),
        adapterRegistry: ProviderAdapterRegistry(adapters: [])
    )
}

/// Records a real two-sample downward burn on `account`'s five-hour window
/// (1.0 → 0.9, 60s apart) ending at `endingAt`, so
/// `ActiveUsageDetector.mostActive` — the exact function `capturePin` feeds
/// through `ActiveUsageMap.compute` — marks it active with
/// `lastUsedAt == endingAt`. Calling this again later for the same account
/// with a later `endingAt` makes it "win" over any other account whose most
/// recent burn is earlier, letting tests flip which account is active between
/// two captures and so tell a fresh capture apart from a stale one.
@MainActor
private func recordActivity(for account: AccountRecord, in history: UsageHistoryStore, endingAt: Date) {
    history.record(
        account: account,
        snapshot: UsageSnapshot(
            accountID: account.id,
            fetchedAt: endingAt.addingTimeInterval(-60),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 1.0, resetsAt: nil),
            weekly: nil
        )
    )
    history.record(
        account: account,
        snapshot: UsageSnapshot(
            accountID: account.id,
            fetchedAt: endingAt,
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.9, resetsAt: nil),
            weekly: nil
        )
    )
}

/// No-op `WebProfileManaging`: the capture tests never sign in or remove an
/// account, so nothing here needs to touch real WebKit-backed storage.
@MainActor
private final class WebProfileManagingStub: WebProfileManaging {
    func makeWebView(profileID: UUID) -> WKWebView { WKWebView(frame: .zero) }
    func removeProfile(profileID: UUID) async throws {}
}

@MainActor
private final class DelegateHarness {
    let delegate = RationApplicationDelegate()
    let model = AppModel.live(
        adapters: LiveProviderAdapters.all,
        baseDirectory: FileManager.default.temporaryDirectory.appending(
            path: UUID().uuidString,
            directoryHint: .isDirectory
        )
    )
    let launchAtLogin = LaunchAtLoginController()
    let hotKeyRegistrar = HotKeyRegistrarSpy()

    func stop() {
        delegate.applicationWillTerminate(
            Notification(name: NSApplication.willTerminateNotification)
        )
    }
}
