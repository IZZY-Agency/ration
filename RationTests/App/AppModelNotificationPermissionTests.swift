import XCTest
@testable import Ration

/// "Never asked" is not "denied". An app appears in System Settings ›
/// Notifications only after it has requested authorization once, so a
/// never-asked Ration that reported "blocked" sent the user to a list it
/// wasn't in. The fix is an explicit **Allow Notifications** click that asks
/// through the serialized reconciler — and nothing else may ever prompt.
@MainActor
final class AppModelNotificationPermissionTests: XCTestCase {

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

    /// Alerts already enabled on disk (so startup only READS the status) and
    /// macOS has never been asked.
    private func makeNeverAskedFixture() async throws -> AlertsFixture {
        let directory = try makeTempDirectory()
        try seedUsageAlertsEnabled(in: directory)
        let scheduler = NotificationSchedulingSpy()
        await scheduler.setAuthorizationStatusResult(.notDetermined)
        return try makeAlertsFixture(directory: directory, scheduler: scheduler)
    }

    // MARK: - Startup

    func testStartupWithNeverAskedPublishesNotDeterminedKeepsGateClosedAndNeverPrompts() async throws {
        let fixture = try await makeNeverAskedFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        XCTAssertEqual(fixture.model.notificationPermission, .notDetermined)
        XCTAssertEqual(fixture.model.usageAlertsAuthorized, false, "not asked yet cannot post")
        XCTAssertFalse(fixture.model.alertsActiveForTesting())
        XCTAssertEqual(
            NotificationAccess.problem(alertsEnabled: true, permission: fixture.model.notificationPermission),
            .needsPermission,
            "never asked must offer Allow, not System Settings"
        )
        let prompts = await fixture.scheduler.requestAuthorizationCallCount
        XCTAssertEqual(prompts, 0, "launch must never prompt")
    }

    func testRecheckWithNeverAskedNeverPrompts() async throws {
        let fixture = try await makeNeverAskedFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        await fixture.model.recheckNotificationAuthorization().value

        XCTAssertEqual(fixture.model.notificationPermission, .notDetermined)
        XCTAssertFalse(fixture.model.alertsActiveForTesting())
        let prompts = await fixture.scheduler.requestAuthorizationCallCount
        XCTAssertEqual(prompts, 0, "a focus change must never prompt")
    }

    // MARK: - Allow click

    func testAllowClickPromptsOnceOpensGateWithoutBacklogAndKeepsSetting() async throws {
        let fixture = try await makeNeverAskedFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let accountID = try await signIn(fixture)
        // A warning crossing while never asked: posts nothing.
        try await save(fixture, accountID, remaining: 0.20, at: 2_000)

        await fixture.scheduler.setAuthorizationResult(true)
        await fixture.model.requestNotificationPermission().value
        await fixture.model.flushAlertEvaluations()

        let prompts = await fixture.scheduler.requestAuthorizationCallCount
        XCTAssertEqual(prompts, 1, "the click asks macOS exactly once")
        XCTAssertEqual(fixture.model.notificationPermission, .allowed)
        XCTAssertTrue(fixture.model.alertsActiveForTesting(), "allowed must open the posting gate")
        XCTAssertTrue(fixture.model.settings.usageAlertsEnabled, "the click never touches the setting")
        let postsAtFlip = await fixture.scheduler.posts
        XCTAssertTrue(postsAtFlip.isEmpty, "allowing must not replay the pre-allow crossing")

        try await save(fixture, accountID, remaining: 0.05, at: 3_000)
        let posts = await fixture.scheduler.posts
        XCTAssertTrue(posts.contains { $0.id == thresholdID(.critical, 90, accountID) },
                      "the next crossing after allowing must post")
        XCTAssertFalse(posts.contains { $0.id == thresholdID(.warning, 75, accountID) },
                       "the crossing observed before allowing must never post")
    }

    /// The allow's prime keeps a crossing the sink never evaluated (a
    /// threshold lowered under current usage while not asked) out of the
    /// first post after the gate opens.
    func testAllowClickPrimesCrossingsTheSinkNeverEvaluated() async throws {
        let fixture = try await makeNeverAskedFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let accountID = try await signIn(fixture)
        try await save(fixture, accountID, remaining: 0.40, at: 2_000) // 60% used, under 75%

        try await fixture.model.setWarningPercent(50, provider: .claude, window: .fiveHour)
        await fixture.model.flushAlertEvaluations()

        await fixture.scheduler.setAuthorizationResult(true)
        await fixture.model.requestNotificationPermission().value
        try await save(fixture, accountID, remaining: 0.40, at: 3_000) // same usage, new poll

        let posts = await fixture.scheduler.posts
        XCTAssertTrue(posts.isEmpty, "a crossing from before the allow must not post after it: \(posts.map(\.id))")
    }

    func testAllowClickDeniedShowsBlockedCopyAndKeepsGateClosed() async throws {
        let fixture = try await makeNeverAskedFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        await fixture.scheduler.setAuthorizationResult(false)
        await fixture.model.requestNotificationPermission().value

        XCTAssertEqual(fixture.model.notificationPermission, .denied)
        XCTAssertFalse(fixture.model.alertsActiveForTesting())
        XCTAssertEqual(
            NotificationAccess.problem(alertsEnabled: true, permission: fixture.model.notificationPermission),
            .blocked,
            "once refused, only System Settings can help"
        )
        XCTAssertTrue(fixture.model.settings.usageAlertsEnabled)
    }

    /// An errored request returns false without macOS recording an answer.
    /// Publishing `.denied` would swap the Allow button for a System Settings
    /// link to a list Ration still isn't in — publish what macOS reports.
    func testAllowClickErroredRequestPublishesReportedStatus() async throws {
        let fixture = try await makeNeverAskedFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        await fixture.scheduler.failNextRequestWithoutAnswer()
        await fixture.model.requestNotificationPermission().value

        let prompts = await fixture.scheduler.requestAuthorizationCallCount
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(fixture.model.notificationPermission, .notDetermined)
        XCTAssertEqual(
            NotificationAccess.problem(alertsEnabled: true, permission: fixture.model.notificationPermission),
            .needsPermission
        )
        XCTAssertFalse(fixture.model.alertsActiveForTesting())
    }

    /// Same rule for the Usage-alerts toggle's own prompt.
    func testToggleOnErroredRequestPublishesReportedStatus() async throws {
        let scheduler = NotificationSchedulingSpy()
        await scheduler.setAuthorizationStatusResult(.notDetermined)
        let fixture = try makeAlertsFixture(scheduler: scheduler)
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        await scheduler.failNextRequestWithoutAnswer()
        try await fixture.model.setUsageAlertsEnabled(true)

        XCTAssertEqual(fixture.model.notificationPermission, .notDetermined)
        XCTAssertFalse(fixture.model.alertsActiveForTesting())
        XCTAssertTrue(fixture.model.settings.usageAlertsEnabled)
    }

    func testAllowClickWithAlertsOffDoesNothing() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        await fixture.model.requestNotificationPermission().value

        let prompts = await fixture.scheduler.requestAuthorizationCallCount
        XCTAssertEqual(prompts, 0, "a stale button must not prompt while alerts are off")
        XCTAssertNil(fixture.model.notificationPermission)
        XCTAssertFalse(fixture.model.alertsActiveForTesting())
        XCTAssertFalse(fixture.model.settings.usageAlertsEnabled, "and must not turn alerts on")
    }

    /// The click claims no version, so a toggle-off landing while the macOS
    /// prompt is up supersedes it: the late "Allow" must not reopen the gate.
    func testAllowClickSupersededByToggleOffDoesNotOpenGate() async throws {
        let fixture = try await makeNeverAskedFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        await fixture.scheduler.armAuthorizationGate()
        let allow = fixture.model.requestNotificationPermission()
        await fixture.scheduler.waitUntilAuthorizationRequestIsSuspended()

        let off = fixture.model.requestSetUsageAlerts(false)
        await fixture.scheduler.releaseAuthorizationRequest(returning: true)
        await allow.value
        try await off.value

        XCTAssertFalse(fixture.model.alertsActiveForTesting(), "a superseded allow must not open the gate")
        XCTAssertEqual(fixture.model.notificationPermission, .notDetermined,
                       "a superseded allow must not publish its answer")
        XCTAssertFalse(fixture.model.settings.usageAlertsEnabled)
    }
}
