import AppKit
import SwiftUI
import XCTest
@testable import Ration

/// Settings › General › Diagnostics › Test drop: the sample goes through the
/// real presentation path, and its ✕ and rows record NOTHING — no snooze, no
/// per-row dismissal, no persisted alert state, no notification — while real
/// crossings keep being handled normally around it.
@MainActor
final class MenuBarTestDropTests: XCTestCase {
    /// One clock for the model, the snapshots and the controller, so every
    /// snapshot below is current evidence and really is evaluated.
    private static let now = Date(timeIntervalSince1970: 3_000)

    private struct Setup {
        let fixture: AlertsFixture
        let account: AccountRecord
        let controller: MenuBarController
        let popover: TestDropPopoverSpy
    }

    /// A signed-in Claude account with alerts on and a REAL weekly critical
    /// crossing already evaluated: posted, remembered and persisted. The
    /// baseline is asserted, so every "unchanged" check below compares
    /// against populated state rather than an empty one.
    private func makeSetup() async throws -> Setup {
        let fixture = try makeAlertsFixture(now: { Self.now })
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        let account = try XCTUnwrap(fixture.model.accounts.first)
        try await fixture.model.setUsageAlertsEnabled(true)

        try await save(fixture, account, at: -60, fiveHour: 0.90, weekly: 0.05)
        await fixture.model.flushAlertEvaluations()

        XCTAssertEqual(
            fixture.model.alertStateForTesting(accountID: account.id)?.weekly.notifiedTier,
            .critical,
            "premise: the real crossing was evaluated"
        )
        let posts = await fixture.scheduler.posts
        XCTAssertEqual(posts.filter { $0.id == weeklyCriticalID(account) }.count, 1, "premise: it was posted")
        XCTAssertNotNil(try? Data(contentsOf: alertFile(fixture)), "premise: it was persisted")
        XCTAssertEqual(fixture.model.attentionRows(now: Self.now).count, 1, "premise: one real row")

        let popover = TestDropPopoverSpy()
        let controller = MenuBarController(
            model: fixture.model,
            launchAtLogin: LaunchAtLoginController(),
            popover: popover,
            hotKeyRegistrar: HotKeyRegistrarSpy(),
            now: { Self.now },
            statusItemIsAnchored: { true }
        )
        controller.start()
        return Setup(fixture: fixture, account: account, controller: controller, popover: popover)
    }

    func testTestDropRecordsNothingThroughItsXOrItsRows() async throws {
        let setup = try await makeSetup()
        let fixture = setup.fixture
        let controller = setup.controller
        defer {
            controller.stop()
            fixture.removeFiles()
        }
        let realRowIDs = fixture.model.attentionRows(now: Self.now).map(\.id)
        let stateBefore = fixture.model.alertStateForTesting(accountID: setup.account.id)
        let fileBefore = try? Data(contentsOf: alertFile(fixture))
        let postsBefore = await fixture.scheduler.posts.count

        // Through the ✕.
        controller.showTestAttentionDrop()
        XCTAssertTrue(controller.attentionPresence.isShowing)
        XCTAssertEqual(
            Set(controller.attentionRowsOnScreen.map(\.accountID)),
            AttentionDropSample.accountIDs,
            "the test drop shows the sample, never the real rows"
        )
        controller.refreshAttentionDrop()
        XCTAssertTrue(controller.isShowingTestAttentionDrop, "the sample survives a refresh tick")
        controller.dismissAttentionDrop()
        XCTAssertFalse(controller.isShowingTestAttentionDrop)

        // Through a row.
        controller.showTestAttentionDrop()
        let sampleRow = try XCTUnwrap(controller.attentionRowsOnScreen.first)
        controller.selectAttentionRow(sampleRow)
        XCTAssertFalse(controller.isShowingTestAttentionDrop)
        XCTAssertTrue(setup.popover.isShown, "a row still opens the popover")

        await fixture.model.flushAlertEvaluations()
        XCTAssertFalse(fixture.model.settings.dropSnoozed, "the test ✕ must not snooze real crossings")
        XCTAssertEqual(fixture.model.alertStateForTesting(accountID: setup.account.id), stateBefore)
        XCTAssertEqual(try? Data(contentsOf: alertFile(fixture)), fileBefore)
        let postsAfter = await fixture.scheduler.posts.count
        XCTAssertEqual(postsAfter, postsBefore)

        // The real crossing comes straight back.
        XCTAssertEqual(controller.attentionRowsOnScreen.map(\.id), realRowIDs)
    }

    /// A real crossing that lands while a delayed test drop is pending, and
    /// another while the sample is on screen, are each evaluated, posted and
    /// remembered exactly as without a test drop — and both are on the drop
    /// once the test ends.
    func testRealCrossingsDuringDelayAndWhileSampleShowsAreHandledNormally() async throws {
        let setup = try await makeSetup()
        let fixture = setup.fixture
        let controller = setup.controller
        let account = setup.account
        defer {
            controller.stop()
            fixture.removeFiles()
        }

        // Long enough that only the seam below ends it: no timer race.
        controller.showTestAttentionDrop(after: 600)
        XCTAssertTrue(controller.hasPendingTestAttentionDrop)

        // During the delay: the 5-hour window crosses critical.
        try await save(fixture, account, at: -40, fiveHour: 0.05, weekly: 0.05)
        await fixture.model.flushAlertEvaluations()
        XCTAssertTrue(controller.hasPendingTestAttentionDrop, "premise: still inside the delay")
        XCTAssertEqual(
            fixture.model.alertStateForTesting(accountID: account.id)?.fiveHour.notifiedTier,
            .critical
        )
        var posts = await fixture.scheduler.posts
        XCTAssertEqual(posts.filter { $0.id == fiveHourCriticalID(account) }.count, 1)

        controller.firePendingTestAttentionDropForTesting()
        XCTAssertTrue(controller.isShowingTestAttentionDrop)

        // While the sample shows: the Fable weekly window crosses critical.
        try await save(fixture, account, at: -20, fiveHour: 0.05, weekly: 0.05, modelWeekly: 0.05)
        await fixture.model.flushAlertEvaluations()
        XCTAssertEqual(
            fixture.model.alertStateForTesting(accountID: account.id)?.modelWeekly.notifiedTier,
            .critical
        )
        posts = await fixture.scheduler.posts
        XCTAssertEqual(posts.filter { $0.id == modelWeeklyCriticalID(account) }.count, 1)
        XCTAssertTrue(controller.isShowingTestAttentionDrop, "the sample stays up over the real change")
        XCTAssertEqual(
            Set(controller.attentionRowsOnScreen.map(\.accountID)),
            AttentionDropSample.accountIDs
        )

        controller.dismissAttentionDrop()
        XCTAssertFalse(fixture.model.settings.dropSnoozed)
        let shown = Set(controller.attentionRowsOnScreen.map(\.subject))
        XCTAssertEqual(shown, [.window(.fiveHour), .window(.weekly), .window(.modelWeekly)])
    }

    /// The Settings button's delayed drop appears on its own, and a `stop()`
    /// in between cancels it rather than resurrecting a panel on a dead
    /// controller.
    func testDelayedTestDropAppearsAndStopCancelsAPendingOne() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        let controller = MenuBarController(
            model: fixture.model,
            launchAtLogin: LaunchAtLoginController(),
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        controller.showTestAttentionDrop(after: 0.05)
        XCTAssertFalse(controller.isShowingTestAttentionDrop, "not before the delay")
        await waitUntil { controller.isShowingTestAttentionDrop }
        XCTAssertTrue(controller.isShowingTestAttentionDrop)
        controller.stop()

        let cancelled = MenuBarController(
            model: fixture.model,
            launchAtLogin: LaunchAtLoginController(),
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        cancelled.showTestAttentionDrop(after: 0.05)
        cancelled.stop()
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(cancelled.isShowingTestAttentionDrop)
        XCTAssertFalse(cancelled.attentionPresence.isShowing)
    }

    // MARK: - Both Settings routes expose Diagnostics

    /// `MenuBarController.showSettings` — the status item's Settings.
    func testControllerSettingsWindowOffersTheTestDrop() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let controller = MenuBarController(
            model: fixture.model,
            launchAtLogin: LaunchAtLoginController(),
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        defer { controller.stop() }

        controller.showSettings()
        let window = try XCTUnwrap(controller.settingsWindowForTesting)
        let hosting = try XCTUnwrap(window.contentViewController as? NSHostingController<SettingsView>)
        let action = try XCTUnwrap(hosting.rootView.onShowTestDrop, "Diagnostics would be hidden")

        action()
        XCTAssertTrue(controller.hasPendingTestAttentionDrop, "it reaches this controller's drop")
    }

    /// The SwiftUI `Window("Settings")` scene — ⌘, and the scene popover.
    func testSceneSettingsOffersTheTestDrop() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let controller = MenuBarController(
            model: fixture.model,
            launchAtLogin: LaunchAtLoginController(),
            hotKeyRegistrar: HotKeyRegistrarSpy()
        )
        defer { controller.stop() }

        let content = SettingsWindowContent(
            model: fixture.model,
            launchAtLogin: LaunchAtLoginController(),
            appearance: AppearanceController(),
            onOpenSetupGuide: {},
            onShowTestDrop: SettingsTestDrop.action { controller }
        )
        let action = try XCTUnwrap(content.settingsView.onShowTestDrop, "Diagnostics would be hidden")

        action()
        XCTAssertTrue(controller.hasPendingTestAttentionDrop, "it reaches the controller's drop")
    }

    // MARK: - Helpers

    private func save(
        _ fixture: AlertsFixture,
        _ account: AccountRecord,
        at offset: TimeInterval,
        fiveHour: Double,
        weekly: Double,
        modelWeekly: Double? = nil
    ) async throws {
        var fable: UsageWindow?
        if let modelWeekly {
            fable = UsageWindow(kind: .modelWeekly, remainingFraction: modelWeekly, resetsAt: nil)
        }
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: account.id,
            fetchedAt: Self.now.addingTimeInterval(offset),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: fiveHour, resetsAt: nil),
            weekly: UsageWindow(kind: .weekly, remainingFraction: weekly, resetsAt: nil),
            modelWeekly: fable
        ))
    }

    private func alertFile(_ fixture: AlertsFixture) -> URL {
        fixture.directory.appending(path: "alert-state.json")
    }

    private func criticalID(_ kind: UsageWindowKind, _ account: AccountRecord) -> String {
        AlertMessage.id(for: .threshold(kind: kind, tier: .critical, percent: 90), accountID: account.id)
    }

    private func weeklyCriticalID(_ account: AccountRecord) -> String { criticalID(.weekly, account) }
    private func fiveHourCriticalID(_ account: AccountRecord) -> String { criticalID(.fiveHour, account) }
    private func modelWeeklyCriticalID(_ account: AccountRecord) -> String { criticalID(.modelWeekly, account) }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }
}

/// Records presentation without drawing a real popover.
@MainActor
private final class TestDropPopoverSpy: PopoverPresenting {
    private(set) var isShown = false
    var behavior: NSPopover.Behavior = .transient
    var contentViewController: NSViewController?
    var appearance: NSAppearance?
    var hasFullSizeContent = false
    weak var delegate: (any NSPopoverDelegate)?

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) {
        isShown = true
    }

    func performClose(_ sender: Any?) { isShown = false }
    func close() { isShown = false }
}
