import XCTest
@testable import Ration

/// API budget rows in the shared drop: the ✕ snooze contract and click routing,
/// with a real AppModel as the bridge.
final class MenuBarAPIDropTests: APISpendModelTestCase {
    private var fixture: AlertsFixture!

    private func wire() async throws -> (APISpendModel, UUID) {
        let appDir = try makeTempDirectory()
        try seedUsageAlertsEnabled(in: appDir)
        fixture = try makeAlertsFixture(directory: appDir)
        try await fixture.model.load(startBackgroundRefresh: false)
        settings = fixture.model.settings
        let id = try await seedOrg(budget: 60_000)
        let model = makeModel()
        model.bridge = fixture.model
        await model.start()
        return (model, id)
    }

    override func tearDown() async throws {
        fixture?.removeFiles()
        try await super.tearDown()
    }

    func testSubscriptionSnoozeIsLiftedByAnAPIMonthAdvance() async throws {
        let (model, id) = try await wire()
        fixture.model.snoozeAttentionDrop([])
        XCTAssertTrue(fixture.model.settings.data.dropSnoozed)
        model.injectMemoryForTesting(id, BudgetAlertMemory(evaluatedMonthKey: "2026-08", notifiedTier: .critical, dismissedTier: nil))
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "1", fetchedAt: now))]
        await model.refresh(id)
        XCTAssertFalse(fixture.model.settings.data.dropSnoozed)
    }

    func testAnAPIEscalationDoesNotLiftTheSnoozeButStillNotifies() async throws {
        let (model, id) = try await wire()
        fixture.model.snoozeAttentionDrop([])
        model.injectMemoryForTesting(id, BudgetAlertMemory(evaluatedMonthKey: "2026-09", notifiedTier: nil, dismissedTier: nil))
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "46000", fetchedAt: now))]
        await model.refresh(id)
        await fixture.model.flushAlertEvaluations()
        XCTAssertTrue(fixture.model.settings.data.dropSnoozed, "an escalation never lifts the ✕ (AppModel ✕ contract)")
        let posts = await fixture.scheduler.posts
        XCTAssertTrue(posts.contains { $0.id == "\(id.uuidString).budget.2026-09.warning" })
        XCTAssertTrue(model.attentionRows(now: now).isEmpty, "snoozed drop shows no API rows")
    }

    func testDropChannelOffMeansNoSnoozeLift() async throws {
        let (model, id) = try await wire()
        try await fixture.model.settings.setChannels(AlertChannels(notification: true, drop: false), forKey: AppSettingsData.apiBudgetsKey)
        fixture.model.snoozeAttentionDrop([])
        model.injectMemoryForTesting(id, BudgetAlertMemory(evaluatedMonthKey: "2026-08", notifiedTier: .critical, dismissedTier: nil))
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "1", fetchedAt: now))]
        await model.refresh(id)
        XCTAssertTrue(fixture.model.settings.data.dropSnoozed)
    }

    func testRowsAppearAndAClickIsRoutedToTheAPIModel() async throws {
        let (model, id) = try await wire()
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "46000", fetchedAt: now))]
        await model.refresh(id)
        let rows = model.attentionRows(now: now)
        XCTAssertEqual(rows.map(\.owner), [.apiOrg(id)])
        XCTAssertEqual(rows.first?.budgetCents, 60_000)
        let controller = MenuBarController(model: fixture.model, launchAtLogin: LaunchAtLoginController(),
                                           popover: ShownPopoverSpy(), hotKeyRegistrar: HotKeyRegistrarSpy(),
                                           now: { [unowned self] in self.now }, apiSpend: model, statusItemIsAnchored: { true })
        controller.selectAttentionRow(try XCTUnwrap(rows.first))
        XCTAssertEqual(model.state.memory[id]?.dismissedTier, .warning)
        XCTAssertTrue(model.attentionRows(now: now).isEmpty, "a clicked row stays dismissed until escalation")
    }
}

/// Reports itself already shown, so a row click never opens a real window in tests.
private final class ShownPopoverSpy: PopoverPresenting {
    private(set) var isShown = true
    var behavior: NSPopover.Behavior = .transient
    var contentViewController: NSViewController?
    var appearance: NSAppearance?
    var hasFullSizeContent = false
    weak var delegate: (any NSPopoverDelegate)?

    func show(relativeTo positioningRect: NSRect, of positioningView: NSView, preferredEdge: NSRectEdge) { isShown = true }
    func performClose(_ sender: Any?) { isShown = false }
    func close() { isShown = false }
}
