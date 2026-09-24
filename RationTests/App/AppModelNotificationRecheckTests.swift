import XCTest
@testable import Ration

/// `recheckNotificationAuthorization()`: the mid-session re-read of the OS
/// notification permission (app activation / a window becoming key). Before
/// it existed, `alertsActive` was decided once per process (startup pass) or
/// per General-toggle tap, so allowing notifications in System Settings kept
/// posts dropped until relaunch, and revoking left the gate open with posts
/// vanishing silently and no banner.
@MainActor
final class AppModelNotificationRecheckTests: XCTestCase {

    // MARK: - Helpers

    private func signIn(_ fixture: AlertsFixture) async throws -> UUID {
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        return try XCTUnwrap(fixture.model.accounts.first).id
    }

    private func save(_ fixture: AlertsFixture, _ accountID: UUID, remaining: Double, at time: TimeInterval) async throws {
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: time),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: remaining, resetsAt: nil),
            weekly: nil
        ))
        await fixture.model.flushAlertEvaluations()
    }

    private func thresholdID(_ tier: AlertTier, _ percent: Int, _ accountID: UUID) -> String {
        AlertMessage.id(for: .threshold(kind: .fiveHour, tier: tier, percent: percent), accountID: accountID)
    }

    /// Alerts enabled on disk; the OS status the startup pass will read.
    private func makeEnabledFixture(statusAtLaunch: Bool) async throws -> AlertsFixture {
        let directory = try makeTempDirectory()
        try seedUsageAlertsEnabled(in: directory)
        let scheduler = NotificationSchedulingSpy()
        await scheduler.setAuthorizationStatusResult(statusAtLaunch)
        return try makeAlertsFixture(directory: directory, scheduler: scheduler)
    }

    // MARK: - 1. Denied at launch, allowed mid-session

    func testAllowingMidSessionActivatesOnRecheckWithoutBacklogThenNextCrossingPosts() async throws {
        let fixture = try await makeEnabledFixture(statusAtLaunch: false)
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        XCTAssertFalse(fixture.model.alertsActiveForTesting(), "arrange: denied at launch")
        XCTAssertEqual(fixture.model.usageAlertsAuthorized, false)

        let accountID = try await signIn(fixture)
        // A warning crossing while notifications are denied: posts nothing.
        try await save(fixture, accountID, remaining: 0.20, at: 2_000)

        // User allows notifications in System Settings, then comes back.
        await fixture.scheduler.setAuthorizationStatusResult(true)
        await fixture.model.recheckNotificationAuthorization().value
        await fixture.model.flushAlertEvaluations()

        XCTAssertTrue(fixture.model.alertsActiveForTesting(), "recheck must open the posting gate")
        XCTAssertEqual(fixture.model.usageAlertsAuthorized, true)
        let postsAtFlip = await fixture.scheduler.posts
        XCTAssertTrue(postsAtFlip.isEmpty, "activating on recheck must not replay the pre-allow crossing")

        try await save(fixture, accountID, remaining: 0.05, at: 3_000)
        let posts = await fixture.scheduler.posts
        XCTAssertTrue(posts.contains { $0.id == thresholdID(.critical, 90, accountID) },
                      "the next crossing after the recheck must post")
        XCTAssertFalse(posts.contains { $0.id == thresholdID(.warning, 75, accountID) },
                       "the crossing observed while denied must never post")
        let prompts = await fixture.scheduler.requestAuthorizationCallCount
        XCTAssertEqual(prompts, 0, "a recheck must never prompt")
    }

    /// The flip's prime is what keeps a crossing the sink never evaluated out
    /// of the first post after activation: a threshold lowered under current
    /// usage while unauthorized is not re-evaluated (that path is gated on
    /// the posting gate), so without the prime the next unchanged poll would
    /// post it as a backlog alert.
    func testActivationOnRecheckPrimesCrossingsTheSinkNeverEvaluated() async throws {
        let fixture = try await makeEnabledFixture(statusAtLaunch: false)
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let accountID = try await signIn(fixture)
        try await save(fixture, accountID, remaining: 0.40, at: 2_000) // 60% used, under 75%

        try await fixture.model.setWarningPercent(50, provider: .claude, window: .fiveHour)
        await fixture.model.flushAlertEvaluations()

        await fixture.scheduler.setAuthorizationStatusResult(true)
        await fixture.model.recheckNotificationAuthorization().value
        try await save(fixture, accountID, remaining: 0.40, at: 3_000) // same usage, new poll

        let posts = await fixture.scheduler.posts
        XCTAssertTrue(posts.isEmpty, "a crossing from before the allow must not post after it: \(posts.map(\.id))")
    }

    /// A crossing observed while denied must not survive in the side-effect
    /// queue and post once a recheck opens the gate. Persistence is held
    /// across the permission flip so the post sits behind a suspended save.
    func testCrossingQueuedWhileDeniedDoesNotPostAfterRecheckOpensGate() async throws {
        let directory = try makeTempDirectory()
        try seedUsageAlertsEnabled(in: directory)
        let hold = AlertSaveHold()
        let store = AlertStateStore(
            fileURL: directory.appending(path: "alert-state.json"),
            saveStates: { _ in await hold.gate() }
        )
        let scheduler = NotificationSchedulingSpy()
        await scheduler.setAuthorizationStatusResult(false)
        let fixture = try makeAlertsFixture(directory: directory, alertStateStore: store, scheduler: scheduler)
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let accountID = try await signIn(fixture)
        try await save(fixture, accountID, remaining: 0.5, at: 2_000)

        hold.arm()
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 3_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await hold.waitUntilSuspended()

        await scheduler.setAuthorizationStatusResult(true)
        await fixture.model.recheckNotificationAuthorization().value
        XCTAssertTrue(fixture.model.alertsActiveForTesting(), "arrange: gate open")

        hold.release()
        await fixture.model.flushAlertEvaluations()
        let posts = await scheduler.posts
        XCTAssertTrue(posts.isEmpty, "a crossing from while denied must not post: \(posts.map(\.id))")
    }

    /// The generation check on its own: a post enqueued while the gate was
    /// open, still queued when a revoke and a re-grant close and reopen it,
    /// belongs to the old activation and must not post in the new one.
    func testPostQueuedAcrossRevokeAndRegrantDoesNotPost() async throws {
        let directory = try makeTempDirectory()
        try seedUsageAlertsEnabled(in: directory)
        let hold = AlertSaveHold()
        let store = AlertStateStore(
            fileURL: directory.appending(path: "alert-state.json"),
            saveStates: { _ in await hold.gate() }
        )
        let scheduler = NotificationSchedulingSpy()
        await scheduler.setAuthorizationStatusResult(true)
        let fixture = try makeAlertsFixture(directory: directory, alertStateStore: store, scheduler: scheduler)
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let accountID = try await signIn(fixture)
        try await save(fixture, accountID, remaining: 0.5, at: 2_000)

        hold.arm()
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 3_000),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: nil),
            weekly: nil
        ))
        await hold.waitUntilSuspended()

        await scheduler.setAuthorizationStatusResult(false)
        await fixture.model.recheckNotificationAuthorization().value
        await scheduler.setAuthorizationStatusResult(true)
        await fixture.model.recheckNotificationAuthorization().value
        XCTAssertTrue(fixture.model.alertsActiveForTesting(), "arrange: gate reopened")

        hold.release()
        await fixture.model.flushAlertEvaluations()
        let posts = await scheduler.posts
        XCTAssertTrue(posts.isEmpty, "a post from a previous activation must not post: \(posts.map(\.id))")
    }

    // MARK: - 2. Allowed at launch, revoked mid-session

    func testRevokingMidSessionClosesGateAndReportsUnauthorizedOnRecheck() async throws {
        let fixture = try await makeEnabledFixture(statusAtLaunch: true)
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        XCTAssertTrue(fixture.model.alertsActiveForTesting(), "arrange: authorized at launch")
        let accountID = try await signIn(fixture)
        try await save(fixture, accountID, remaining: 0.5, at: 2_000)

        await fixture.scheduler.setAuthorizationStatusResult(false)
        await fixture.model.recheckNotificationAuthorization().value

        XCTAssertFalse(fixture.model.alertsActiveForTesting(), "a revoked permission must close the gate")
        XCTAssertEqual(fixture.model.usageAlertsAuthorized, false, "the banner needs to know")

        try await save(fixture, accountID, remaining: 0.05, at: 3_000)
        let posts = await fixture.scheduler.posts
        XCTAssertTrue(posts.isEmpty)
        let prompts = await fixture.scheduler.requestAuthorizationCallCount
        XCTAssertEqual(prompts, 0, "a recheck must never prompt")
    }

    // MARK: - 3. Superseded by a concurrent toggle

    func testRecheckSupersededByConcurrentToggleIsNoOp() async throws {
        let fixture = try await makeEnabledFixture(statusAtLaunch: true)
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        XCTAssertTrue(fixture.model.alertsActiveForTesting(), "arrange: authorized at launch")

        // Pin the recheck inside its status query.
        await fixture.scheduler.armStatusGate()
        let recheck = fixture.model.recheckNotificationAuthorization()
        await fixture.scheduler.waitUntilStatusQueryIsSuspended()

        // A toggle lands meanwhile (claims a newer version); hold its own
        // pass inside requestAuthorization so the state between the two
        // passes is observable.
        await fixture.scheduler.armAuthorizationGate()
        let toggle = fixture.model.requestSetUsageAlerts(true)

        // The stale recheck resolves "revoked".
        await fixture.scheduler.releaseStatusQuery(false)
        await recheck.value
        await fixture.scheduler.waitUntilAuthorizationRequestIsSuspended()

        XCTAssertTrue(fixture.model.alertsActiveForTesting(),
                      "a superseded recheck must not touch the gate")
        XCTAssertEqual(fixture.model.usageAlertsAuthorized, true,
                       "a superseded recheck must not publish its stale answer")

        await fixture.scheduler.releaseAuthorizationRequest(returning: true)
        try await toggle.value
        XCTAssertTrue(fixture.model.alertsActiveForTesting())
    }

    // MARK: - 4. No-op while off / not hydrated / parked

    func testRecheckWithAlertsOffIsNoOp() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let queriesBefore = await fixture.scheduler.authorizationStatusCallCount

        await fixture.model.recheckNotificationAuthorization().value

        let queries = await fixture.scheduler.authorizationStatusCallCount
        let prompts = await fixture.scheduler.requestAuthorizationCallCount
        XCTAssertEqual(queries, queriesBefore, "alerts off: nothing to recheck")
        XCTAssertEqual(prompts, 0)
        XCTAssertNil(fixture.model.usageAlertsAuthorized)
        XCTAssertFalse(fixture.model.alertsActiveForTesting())
    }

    func testRecheckBeforeHydrationIsNoOp() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        // Desired ON before load(): only the hydration barrier stands between
        // a recheck and activating against not-yet-loaded state.
        try await fixture.model.setUsageAlertsEnabled(true)
        XCTAssertFalse(fixture.model.alertsHydratedForTesting(), "arrange: not hydrated")

        await fixture.model.recheckNotificationAuthorization().value

        let queries = await fixture.scheduler.authorizationStatusCallCount
        let prompts = await fixture.scheduler.requestAuthorizationCallCount
        XCTAssertEqual(queries, 0, "before load() hydrates, the startup pass owns activation")
        XCTAssertEqual(prompts, 0)
        XCTAssertNil(fixture.model.usageAlertsAuthorized)
        XCTAssertFalse(fixture.model.alertsActiveForTesting())
    }

    func testRecheckWhileParkedIsNoOp() async throws {
        let scheduler = NotificationSchedulingSpy()
        let saveGate = SettingsSaveGate()
        let hydrationGate = HydrationGate()
        let directory = try makeTempDirectory()
        let settings = AppSettings(
            fileURL: directory.appending(path: "app-settings.json"),
            saveSettings: { data in try await saveGate.gate(data) }
        )
        let fixture = try makeAlertsFixture(
            directory: directory,
            scheduler: scheduler,
            hydrationGate: hydrationGate,
            appSettings: settings
        )
        defer { fixture.removeFiles() }

        // Park: a cold-start enable whose persist fails (desired ON, durable OFF).
        hydrationGate.arm()
        let load = Task { try await fixture.model.load(startBackgroundRefresh: false) }
        await hydrationGate.waitUntilSuspended()
        saveGate.armFailure()
        let enable = fixture.model.requestSetUsageAlerts(true)
        do {
            try await enable.value
            XCTFail("expected the persist failure to surface")
        } catch {}
        hydrationGate.release()
        try await load.value
        let queriesBefore = await scheduler.authorizationStatusCallCount

        await fixture.model.recheckNotificationAuthorization().value

        let queries = await scheduler.authorizationStatusCallCount
        let prompts = await scheduler.requestAuthorizationCallCount
        XCTAssertEqual(queries, queriesBefore, "parked: a recheck must not activate an unestablished desire")
        XCTAssertEqual(prompts, 0)
        XCTAssertNil(fixture.model.usageAlertsAuthorized)
        XCTAssertFalse(fixture.model.alertsActiveForTesting())
    }
}

/// Holds the NEXT alert-state save until released, so a test can keep a
/// post queued behind persistence while it changes the world.
@MainActor
final class AlertSaveHold {
    private var armed = false
    private var pending: CheckedContinuation<Void, Never>?
    private var suspendedSignal: CheckedContinuation<Void, Never>?

    func arm() { armed = true }

    func gate() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation in
            pending = continuation
            suspendedSignal?.resume()
            suspendedSignal = nil
        }
    }

    func waitUntilSuspended() async {
        if pending != nil { return }
        await withCheckedContinuation { suspendedSignal = $0 }
    }

    func release() {
        pending?.resume()
        pending = nil
    }
}
