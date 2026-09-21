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
            hotKeyRegistrar: hotKeyRegistrar
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
    var onShow: (() -> Void)?

    func show(
        relativeTo positioningRect: NSRect,
        of positioningView: NSView,
        preferredEdge: NSRectEdge
    ) {
        isShown = true
        onShow?()
    }

    func performClose(_ sender: Any?) {
        isShown = false
    }

    func close() {
        isShown = false
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
