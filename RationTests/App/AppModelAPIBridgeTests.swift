import XCTest
@testable import Ration

@MainActor
final class AppModelAPIBridgeTests: XCTestCase {
    private func readyFixture() async throws -> AlertsFixture {
        let dir = try makeTempDirectory()
        try seedUsageAlertsEnabled(in: dir)
        let fixture = try makeAlertsFixture(directory: dir)
        try await fixture.model.load(startBackgroundRefresh: false)
        return fixture
    }

    private func post(_ id: String, valid: Bool = true) -> ExternalAlertPost {
        ExternalAlertPost(id: id, stillValid: { valid }, render: { redacted in (redacted ? "R" : "T", "B") })
    }

    func testAlertsReadyOnlyAfterASuccessfulLoad() async throws {
        let dir = try makeTempDirectory()
        try seedUsageAlertsEnabled(in: dir)
        let fixture = try makeAlertsFixture(directory: dir)
        defer { fixture.removeFiles() }
        XCTAssertFalse(fixture.model.alertsReady)
        try await fixture.model.load(startBackgroundRefresh: false)
        XCTAssertTrue(fixture.model.alertsReady)
    }

    func testWrittenDecisionPostsAfterPersist() async throws {
        let fixture = try await readyFixture()
        defer { fixture.removeFiles() }
        var persisted = false
        fixture.model.enqueueExternalAlertDecision(persist: { persisted = true; return .written }, posts: [post("a")])
        await fixture.model.flushAlertEvaluations()
        XCTAssertTrue(persisted)
        let posts = await fixture.scheduler.posts
        XCTAssertEqual(posts.map(\.id), ["a"])
        XCTAssertEqual(posts.first?.title, "T")
    }

    func testStaleDecisionPostsNothing() async throws {
        let fixture = try await readyFixture()
        defer { fixture.removeFiles() }
        fixture.model.enqueueExternalAlertDecision(persist: { .stale }, posts: [post("a")])
        await fixture.model.flushAlertEvaluations()
        let posts = await fixture.scheduler.posts
        XCTAssertTrue(posts.isEmpty)
    }

    func testFailedPersistStillPosts() async throws {
        let fixture = try await readyFixture()
        defer { fixture.removeFiles() }
        fixture.model.enqueueExternalAlertDecision(persist: { .failed }, posts: [post("a")])
        await fixture.model.flushAlertEvaluations()
        let posts = await fixture.scheduler.posts
        XCTAssertEqual(posts.map(\.id), ["a"])
    }

    func testInvalidAtExecutionIsDropped() async throws {
        let fixture = try await readyFixture()
        defer { fixture.removeFiles() }
        fixture.model.enqueueExternalAlertDecision(persist: { .written }, posts: [post("a", valid: false)])
        await fixture.model.flushAlertEvaluations()
        let posts = await fixture.scheduler.posts
        XCTAssertTrue(posts.isEmpty)
    }

    func testGateShutAtEnqueueMeansNoPostButPersistRuns() async throws {
        let fixture = try makeAlertsFixture() // alerts NOT enabled → gate shut
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        var persisted = false
        fixture.model.enqueueExternalAlertDecision(persist: { persisted = true; return .written }, posts: [post("a")])
        await fixture.model.flushAlertEvaluations()
        XCTAssertTrue(persisted)
        let posts = await fixture.scheduler.posts
        XCTAssertTrue(posts.isEmpty)
    }

    func testPrivacyIsReadAtPostTime() async throws {
        let fixture = try await readyFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        fixture.model.enqueueExternalAlertDecision(persist: { await gate.wait(); return .written }, posts: [post("a")])
        // Privacy mode on AFTER enqueue, before the queued post runs.
        try await fixture.model.setRedactNotifications(true)
        await gate.open()
        await fixture.model.flushAlertEvaluations()
        let posts = await fixture.scheduler.posts
        XCTAssertEqual(posts.first?.title, "R")
    }

    func testActivationFlipWhileQueuedDropsThePost() async throws {
        let fixture = try await readyFixture()
        defer { fixture.removeFiles() }
        let gate = AsyncGate()
        fixture.model.enqueueExternalAlertDecision(persist: { await gate.wait(); return .written }, posts: [post("a")])
        _ = try await fixture.model.requestSetUsageAlerts(false).value
        _ = try await fixture.model.requestSetUsageAlerts(true).value
        await gate.open()
        await fixture.model.flushAlertEvaluations()
        let posts = await fixture.scheduler.posts
        XCTAssertTrue(posts.isEmpty, "a post born in one activation must not land in the next")
    }

    func testPrimeHookRunsOnReactivationAndRegistrationReportsTheGate() async throws {
        let fixture = try await readyFixture()
        defer { fixture.removeFiles() }
        var calls = 0
        let open = fixture.model.registerPrimeHook { calls += 1 }
        XCTAssertTrue(open)
        // OFF → ON re-primes (`requestSetUsageAlerts` returns Task<Void, Error>).
        _ = try await fixture.model.requestSetUsageAlerts(false).value
        _ = try await fixture.model.requestSetUsageAlerts(true).value
        XCTAssertEqual(calls, 1)
    }

    func testLiftDropSnoozeAndGate() async throws {
        let fixture = try await readyFixture()
        defer { fixture.removeFiles() }
        let now = Date(timeIntervalSince1970: 1_000)
        fixture.model.snoozeAttentionDrop([])
        XCTAssertFalse(fixture.model.dropGateOpen(at: now))
        fixture.model.liftDropSnooze()
        XCTAssertFalse(fixture.model.settings.data.dropSnoozed)
    }

    /// Regression: with $104.50 spent, lowering the budget from $200 to $100
    /// in Settings once gave no notification and no drop row. The real
    /// AppModel bridge, end to end.
    func testLoweringTheBudgetBelowSpendNotifiesAndShowsADropRow() async throws {
        let fixture = try await readyFixture()
        defer { fixture.removeFiles() }
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let at = ISO8601DateFormatter().date(from: "2026-09-27T18:33:00Z")!
        let id = UUID()
        var state = APISpendState()
        state.orgs = [APIOrgRecord(id: id, vendor: .anthropic, vendorOrgID: "org-1", label: "Work API", monthlyBudgetCents: 20_000,
                                   isPaused: false, displayOrder: 0, createdAt: at)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(state).write(to: dir.appending(path: "api-spend.json"))
        let keys = InMemoryAPIKeyStore()
        keys.seed("sk-ant-admin01-SENTINELSENTINEL", for: id)
        let api = APISpendModel(
            dependencies: .init(clients: [.anthropic: FakeSpendClient(vendor: .anthropic)], keyStore: keys,
                                persistence: APISpendPersistence(stateURL: dir.appending(path: "api-spend.json"),
                                                                 snapshotsURL: dir.appending(path: "api-spend-snapshots.json")),
                                now: { at }, lowPowerMode: { false }, jitter: { 0 }, autoPoll: false),
            settings: fixture.model.settings
        )
        api.bridge = fixture.model
        await api.start()
        let month = UTCMonth(containing: at)
        api.injectSnapshotForTesting(id, APISpendSnapshot(cost: APICostReport(
            month: month, fetchedAt: at, refreshStartedAt: at,
            days: [DayCost(dayStart: month.start, cents: 10_450)], byModel: [], otherCharges: [], byLineItem: [], coversToday: false)))
        api.evaluate(id)                       // the refresh that showed 52 % of $200: no crossing
        await fixture.model.flushAlertEvaluations()
        let before = await fixture.scheduler.posts
        XCTAssertTrue(before.isEmpty)

        api.setBudget(id, cents: 10_000)
        await fixture.model.flushAlertEvaluations()
        let posts = await fixture.scheduler.posts
        XCTAssertEqual(posts.map(\.id), ["\(id.uuidString).budget.2026-09.critical"], "one critical notification")
        XCTAssertEqual(api.attentionRows(now: at).map(\.tier), [.critical], "one drop row")
    }
}
