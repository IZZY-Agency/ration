import AppKit
import WebKit
import XCTest
@testable import Ration

/// The status item lives in AppKit, outside SwiftUI observation, so the usage
/// rings need their own driver: recompute on history/model/settings publishes
/// plus a periodic tick so the in-use dot expires on its own once the last
/// burn ages past the bright IN USE threshold (the ring itself stays — it
/// shows usage, not activity).
@MainActor
final class MenuBarInUseIndicatorTests: XCTestCase {
    private let ring = "\u{FFFC}"

    /// Mutable clock handed to the controller so a test can age the world
    /// without waiting: the timer tick must re-read the clock, not a captured
    /// date.
    private final class ClockBox {
        var now: Date = .now
    }

    func testStartRendersRingForActiveAccountAndTooltipCarriesValue() async throws {
        let account = makeIndicatorAccount(.claude, order: 0)
        let harness = try await makeIndicatorHarness(seedAccounts: [account])
        recordIndicatorActivity(for: account, in: harness.model.history, endingAt: .now)
        try await harness.seedSnapshot(for: account, fiveHourRemaining: 0.14)

        let controller = MenuBarController(
            model: harness.model,
            launchAtLogin: LaunchAtLoginController(),
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        controller.start()
        defer { controller.stop() }
        let button = try XCTUnwrap(controller.statusItem?.button)

        XCTAssertEqual(button.attributedTitle.string, ring)
        XCTAssertEqual(button.toolTip, "Ration — Claude claude-0 5h 86% used (in use)")
    }

    func testIdleAccountRendersRingAndNewBurnAddsInUseWithoutManualCall() async throws {
        let account = makeIndicatorAccount(.chatGPT, order: 0)
        let harness = try await makeIndicatorHarness(seedAccounts: [account])
        try await harness.seedSnapshot(for: account, fiveHourRemaining: 0.87)

        let controller = MenuBarController(
            model: harness.model,
            launchAtLogin: LaunchAtLoginController(),
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        controller.start()
        defer { controller.stop() }
        let button = try XCTUnwrap(controller.statusItem?.button)
        // The ring shows for the idle account already; no in-use marker yet.
        await waitUntil { button.attributedTitle.string == self.ring }
        XCTAssertEqual(button.attributedTitle.string, ring)
        XCTAssertEqual(button.toolTip, "Ration — ChatGPT chatgpt-0 5h 13% used")

        recordIndicatorActivity(for: account, in: harness.model.history, endingAt: .now)

        await waitUntil { button.toolTip?.hasSuffix("(in use)") == true }
        XCTAssertEqual(button.attributedTitle.string, ring)
        XCTAssertEqual(button.toolTip, "Ration — ChatGPT chatgpt-0 5h 13% used (in use)")
    }

    func testToggleOffClearsRingsAndBackOnRestoresThem() async throws {
        let account = makeIndicatorAccount(.claude, order: 0)
        let harness = try await makeIndicatorHarness(seedAccounts: [account])
        recordIndicatorActivity(for: account, in: harness.model.history, endingAt: .now)
        try await harness.seedSnapshot(for: account, fiveHourRemaining: 0.14)

        let controller = MenuBarController(
            model: harness.model,
            launchAtLogin: LaunchAtLoginController(),
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        controller.start()
        defer { controller.stop() }
        let button = try XCTUnwrap(controller.statusItem?.button)
        XCTAssertEqual(button.attributedTitle.string, ring)

        try await harness.model.setShowInUseInMenuBar(false)
        await waitUntil { button.attributedTitle.string.isEmpty }
        XCTAssertEqual(button.attributedTitle.string, "")
        XCTAssertEqual(button.toolTip, "Ration")

        try await harness.model.setShowInUseInMenuBar(true)
        await waitUntil { button.attributedTitle.string == self.ring }
        XCTAssertEqual(button.attributedTitle.string, ring)
    }

    func testTwoAccountsOfSameProviderBothCarryInUse() async throws {
        // The popover pill dedups to one winner per provider; the gauges must
        // NOT — parallel use of two Claude accounts marks both dots.
        let a = makeIndicatorAccount(.claude, order: 0)
        let b = makeIndicatorAccount(.claude, order: 1)
        let harness = try await makeIndicatorHarness(seedAccounts: [a, b])
        recordIndicatorActivity(for: a, in: harness.model.history, endingAt: .now)
        recordIndicatorActivity(for: b, in: harness.model.history, endingAt: .now)
        try await harness.seedSnapshot(for: a, fiveHourRemaining: 0.25)
        try await harness.seedSnapshot(for: b, fiveHourRemaining: 0.5)

        let controller = MenuBarController(
            model: harness.model,
            launchAtLogin: LaunchAtLoginController(),
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        controller.start()
        defer { controller.stop() }
        let button = try XCTUnwrap(controller.statusItem?.button)

        XCTAssertEqual(button.attributedTitle.string, ring + ring)
        XCTAssertEqual(
            button.toolTip,
            "Ration — Claude claude-0 5h 75% used (in use)"
                + " · Claude claude-1 5h 50% used (in use)"
        )
    }

    func testPausedAccountLosesItsRing() async throws {
        let account = makeIndicatorAccount(.claude, order: 0)
        let harness = try await makeIndicatorHarness(seedAccounts: [account])
        try await harness.seedSnapshot(for: account, fiveHourRemaining: 0.14)

        let controller = MenuBarController(
            model: harness.model,
            launchAtLogin: LaunchAtLoginController(),
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        controller.start()
        defer { controller.stop() }
        let button = try XCTUnwrap(controller.statusItem?.button)
        await waitUntil { button.attributedTitle.string == self.ring }
        XCTAssertEqual(button.attributedTitle.string, ring)

        try await harness.model.setPaused(accountID: account.id, paused: true)

        await waitUntil { button.attributedTitle.string.isEmpty }
        XCTAssertEqual(button.attributedTitle.string, "")
        XCTAssertEqual(button.toolTip, "Ration")
    }

    func testWindowSelectionChangeUpdatesRingValue() async throws {
        let account = makeIndicatorAccount(.claude, order: 0)
        let harness = try await makeIndicatorHarness(seedAccounts: [account])
        recordIndicatorActivity(for: account, in: harness.model.history, endingAt: .now)
        try await harness.seedSnapshot(
            for: account, fiveHourRemaining: 0.14, modelWeeklyRemaining: 0.51
        )

        let controller = MenuBarController(
            model: harness.model,
            launchAtLogin: LaunchAtLoginController(),
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        controller.start()
        defer { controller.stop() }
        let button = try XCTUnwrap(controller.statusItem?.button)
        XCTAssertEqual(button.toolTip, "Ration — Claude claude-0 5h 86% used (in use)")

        try await harness.model.setMenuBarWindow(.modelWeekly, for: .claude)

        await waitUntil {
            button.toolTip == "Ration — Claude claude-0 Fable 49% used (in use)"
        }
        XCTAssertEqual(button.toolTip, "Ration — Claude claude-0 Fable 49% used (in use)")
    }

    func testTimerTickExpiresStaleInUseDotButKeepsRing() async throws {
        let clock = ClockBox()
        let account = makeIndicatorAccount(.claude, order: 0)
        let harness = try await makeIndicatorHarness(seedAccounts: [account])
        recordIndicatorActivity(for: account, in: harness.model.history, endingAt: clock.now)
        try await harness.seedSnapshot(for: account, fiveHourRemaining: 0.14)

        let controller = MenuBarController(
            model: harness.model,
            launchAtLogin: LaunchAtLoginController(),
            hotKeyRegistrar: HotKeyRegistrarSpy(),
            now: { clock.now }
        )
        controller.start()
        defer { controller.stop() }
        let button = try XCTUnwrap(controller.statusItem?.button)
        XCTAssertEqual(button.attributedTitle.string, ring)

        // 20 minutes later nothing has published — only the tick can notice
        // the phase expired. If start() never scheduled the timer, fire()
        // no-ops and the stale marker correctly fails the test. The ring
        // itself must survive: it shows usage, not activity.
        clock.now = clock.now.addingTimeInterval(1200)
        controller.inUseTimer?.fire()

        XCTAssertEqual(button.attributedTitle.string, ring)
        XCTAssertEqual(button.toolTip, "Ration — Claude claude-0 5h 86% used")
    }

    func testStopInvalidatesTimer() async throws {
        let harness = try await makeIndicatorHarness(seedAccounts: [])
        let controller = MenuBarController(
            model: harness.model,
            launchAtLogin: LaunchAtLoginController(),
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        controller.start()
        let timer = try XCTUnwrap(controller.inUseTimer)
        XCTAssertTrue(timer.isValid)

        controller.stop()

        XCTAssertFalse(timer.isValid)
        XCTAssertNil(controller.inUseTimer)
    }

    /// The menu bar's OWN appearance flipping (macOS light/dark, wallpaper
    /// tint) must redraw the rings with no data change and no call to
    /// `updateGauges` — only the controller's `effectiveAppearance` KVO can
    /// do that. The redraw is synchronous inside the KVO callback, so nothing
    /// queued can run after `stop()`; after `stop()` a flip draws nothing.
    func testButtonAppearanceFlipRedrawsRingsThroughKVO() async throws {
        let account = makeIndicatorAccount(.claude, order: 0)
        let harness = try await makeIndicatorHarness(seedAccounts: [account])
        recordIndicatorActivity(for: account, in: harness.model.history, endingAt: .now)
        try await harness.seedSnapshot(for: account, fiveHourRemaining: 0.14)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "KVORings-\(UUID())"))

        let controller = MenuBarController(
            model: harness.model,
            launchAtLogin: LaunchAtLoginController(),
            appearance: AppearanceController(defaults: defaults),
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        controller.start()
        let button = try XCTUnwrap(controller.statusItem?.button)
        XCTAssertEqual(button.attributedTitle.string, ring)

        for (name, expected) in [
            (NSAppearance.Name.aqua, UInt32(0x3B7239)), (.darkAqua, 0x8FC79A), (.aqua, 0x3B7239)
        ] {
            button.appearance = NSAppearance(named: name)
            // No run-loop spin: the KVO callback must have redrawn already.
            XCTAssertEqual(try ringDotGreen(button), Double((expected >> 8) & 0xFF) / 255,
                           accuracy: 0.1, "\(name)")
        }

        controller.stop()
        let stale = button.attributedTitle
        button.appearance = NSAppearance(named: .darkAqua)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(button.attributedTitle, stale, "no redraw after stop()")
    }

    /// Green channel of the first ring attachment's centre (the in-use dot).
    private func ringDotGreen(_ button: NSStatusBarButton) throws -> Double {
        let attachment = try XCTUnwrap(
            button.attributedTitle.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment
        )
        let image = try XCTUnwrap(attachment.image)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let color = try XCTUnwrap(rep.colorAt(x: Int(image.size.width / 2), y: Int(image.size.height / 2)))
        return try XCTUnwrap(color.usingColorSpace(.sRGB)).greenComponent
    }

    /// Lets main-queue work (Combine `.receive(on: DispatchQueue.main)`
    /// deliveries) drain between checks.
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

@MainActor
private func makeIndicatorAccount(_ provider: Provider, order: Int) -> AccountRecord {
    AccountRecord(
        id: UUID(), provider: provider, label: "\(provider.rawValue)-\(order)",
        webProfileID: UUID(), displayOrder: order,
        createdAt: Date(timeIntervalSince1970: 0)
    )
}

/// A real `AppModel` via its designated initializer — seeded accounts are
/// present immediately; the harness keeps the snapshot store so tests can seed
/// the display values the rings read.
@MainActor
private struct IndicatorHarness {
    let model: AppModel
    let snapshotStore: UsageSnapshotStore

    func seedSnapshot(
        for account: AccountRecord,
        fiveHourRemaining: Double,
        modelWeeklyRemaining: Double? = nil
    ) async throws {
        try await snapshotStore.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: .now,
            fiveHour: UsageWindow(
                kind: .fiveHour, remainingFraction: fiveHourRemaining, resetsAt: nil
            ),
            weekly: nil,
            modelWeekly: modelWeeklyRemaining.map {
                UsageWindow(kind: .modelWeekly, remainingFraction: $0, resetsAt: nil)
            }
        ))
    }
}

@MainActor
private func makeIndicatorHarness(seedAccounts: [AccountRecord]) async throws -> IndicatorHarness {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    let accountStore = AccountStore(
        fileURL: directory.appending(path: "accounts.json")
    )
    for account in seedAccounts {
        try await accountStore.add(account)
    }
    let snapshotStore = UsageSnapshotStore(
        fileURL: directory.appending(path: "snapshots.json")
    )
    let model = AppModel(
        accountStore: accountStore,
        snapshotStore: snapshotStore,
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
        profileManager: IndicatorWebProfileStub(),
        adapterRegistry: ProviderAdapterRegistry(adapters: [])
    )
    return IndicatorHarness(model: model, snapshotStore: snapshotStore)
}

/// Records a real two-sample downward burn ending at `endingAt`, so
/// `ActiveUsageDetector.mostActive` marks the account active with
/// `lastUsedAt == endingAt` — the exact pipeline the indicator recomputes.
/// Note this feeds HISTORY only; the display value the ring shows comes from
/// the separately-seeded snapshot store.
@MainActor
private func recordIndicatorActivity(
    for account: AccountRecord,
    in history: UsageHistoryStore,
    endingAt: Date
) {
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

@MainActor
private final class IndicatorWebProfileStub: WebProfileManaging {
    func makeWebView(profileID: UUID) -> WKWebView { WKWebView(frame: .zero) }
    func removeProfile(profileID: UUID) async throws {}
}
