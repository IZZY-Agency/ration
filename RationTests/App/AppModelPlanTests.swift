import XCTest
@testable import Ration

/// Plan tiers through `AppModel`: detection on sign-in
/// and on every refresh, never overwriting a user choice; "Detect
/// automatically" re-applies the latest reading; the add-account plan step.
@MainActor
final class AppModelPlanTests: XCTestCase {
    private func signIn(_ fixture: AlertsFixture, provider: Provider = .claude) async throws -> UUID {
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: provider)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        return try XCTUnwrap(fixture.model.accounts.last).id
    }

    private func account(_ fixture: AlertsFixture, _ id: UUID) -> AccountRecord? {
        fixture.model.accounts.first { $0.id == id }
    }

    func testSignInStoresTheDetectedPlan() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.planDetection = .tier(.claudeMax20x)
        let id = try await signIn(fixture)
        XCTAssertEqual(account(fixture, id)?.plan, .claudeMax20x)
        XCTAssertEqual(account(fixture, id)?.planSource, .detected)
    }

    func testRefreshUpdatesADetectedPlanButNeverAUserChoice() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.planDetection = .tier(.claudeMax5x)
        let id = try await signIn(fixture)

        fixture.adapter.planDetection = .tier(.claudeMax20x)
        await fixture.model.refreshAll()
        XCTAssertEqual(account(fixture, id)?.plan, .claudeMax20x)

        try await fixture.model.requestSetPlan(accountID: id, plan: .claudePro).value
        XCTAssertEqual(account(fixture, id)?.planSource, .user)
        await fixture.model.refreshAll()
        XCTAssertEqual(account(fixture, id)?.plan, .claudePro, "detection never overwrites a user choice")
    }

    func testDetectAutomaticallyReappliesTheLatestReading() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.planDetection = .tier(.claudeMax20x)
        let id = try await signIn(fixture)
        try await fixture.model.requestSetPlan(accountID: id, plan: .claudePro).value
        try await fixture.model.requestSetPlan(accountID: id, plan: nil).value
        XCTAssertEqual(account(fixture, id)?.plan, .claudeMax20x)
        XCTAssertEqual(account(fixture, id)?.planSource, .detected)
    }

    func testUnreadPlanLeavesTheStoredPlanAlone() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.planDetection = .tier(.claudeMax20x)
        let id = try await signIn(fixture)
        fixture.adapter.planDetection = nil
        await fixture.model.refreshAll()
        XCTAssertEqual(account(fixture, id)?.plan, .claudeMax20x)
    }

    // MARK: Readings are kept only for live accounts

    func testReadingForAnUnknownAccountIsNotRemembered() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        _ = try await signIn(fixture)
        let stranger = UUID()
        await fixture.model.applyDetectedPlan(accountID: stranger, detection: .tier(.claudePro), at: .now)
        XCTAssertNil(fixture.model.latestPlanDetectionForTesting(accountID: stranger))
    }

    func testRemovingAnAccountForgetsItsReading() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.planDetection = .tier(.claudeMax20x)
        let id = try await signIn(fixture)
        XCTAssertEqual(fixture.model.latestPlanDetectionForTesting(accountID: id), .tier(.claudeMax20x), "premise")
        try await fixture.model.removeAccount(id: id)
        XCTAssertNil(fixture.model.latestPlanDetectionForTesting(accountID: id))
    }

    // MARK: Add-account plan step

    func testPlanStepShownWhenPlanUnknown() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let id = try await signIn(fixture)
        XCTAssertTrue(fixture.model.needsPlanStep(accountID: id))
    }

    func testPlanStepShownWhenBillingDayUnsetEvenIfPlanDetected() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.planDetection = .tier(.claudeMax20x)
        let id = try await signIn(fixture)
        XCTAssertTrue(fixture.model.needsPlanStep(accountID: id))
        try await fixture.model.requestSetBillingRenewalDay(accountID: id, day: 14).value
        XCTAssertFalse(fixture.model.needsPlanStep(accountID: id), "plan known and billing day set → no step")
    }

    func testPlanStepNeverShownForCursorOrUnknownAccounts() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        let id = try await signIn(fixture, provider: .cursor)
        XCTAssertFalse(fixture.model.needsPlanStep(accountID: id))
        XCTAssertFalse(fixture.model.needsPlanStep(accountID: UUID()))
    }
}
