import XCTest
@testable import Ration

/// `AppModel` hands its Claude accounts to token burn after every snapshot
/// pass, and a removed account's usage is deleted before its link goes.
@MainActor
final class TokenBurnAppModelWiringTests: XCTestCase {
    private func signIn(_ fixture: AlertsFixture, _ label: String) async throws -> AccountRecord {
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: label)
        return try XCTUnwrap(fixture.model.accounts.first { $0.label == label })
    }

    private func tokenBurn(in directory: URL) -> TokenBurnModel {
        TokenBurnModel(dependencies: .init(
            folderAccess: FakeFolderAccess(),
            settings: JSONFileStore(fileURL: directory.appending(path: "token-burn.json"), defaultValue: TokenBurnSettings()),
            databaseURL: directory.appending(path: "token-burn.sqlite"),
            readSignIn: { nil },
            scanInterval: .infinity, readingInterval: .infinity))
    }

    func testASnapshotPassHandsTheClaudeAccountsToTokenBurn() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let work = try await signIn(fixture, "Work")
        let team = try await signIn(fixture, "Team")
        let tokenBurn = tokenBurn(in: fixture.directory)
        fixture.model.tokenBurn = tokenBurn

        try await fixture.snapshots.save(UsageSnapshot(
            accountID: work.id, fetchedAt: Date(timeIntervalSince1970: 1_000), fiveHour: nil, weekly: nil,
            organizationID: "org-W", planDetection: .tier(.claudeMax20x)))
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: team.id, fetchedAt: Date(timeIntervalSince1970: 1_000), fiveHour: nil, weekly: nil,
            organizationID: "org-T", planDetection: .unrecognized))

        XCTAssertEqual(tokenBurn.accounts, [
            TokenBurnAccount(id: work.id, label: "Work", organizationID: "org-W", personalPlanDetected: true,
                             plan: .claudeMax20x, renewalDay: nil),
            TokenBurnAccount(id: team.id, label: "Team", organizationID: "org-T", personalPlanDetected: false,
                             plan: nil, renewalDay: nil),
        ])
    }

    /// A plan the user set is shown and prices the ratio, but only a plan
    /// detected from the organization's own tier proves a single seat.
    func testAPlanSetByTheUserIsNotProofOfOneSeat() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let work = try await signIn(fixture, "Work")
        try await fixture.model.requestSetPlan(accountID: work.id, plan: .claudeMax5x).value
        let tokenBurn = tokenBurn(in: fixture.directory)
        fixture.model.tokenBurn = tokenBurn
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: work.id, fetchedAt: Date(timeIntervalSince1970: 1_000), fiveHour: nil, weekly: nil,
            organizationID: "org-W", planDetection: .unrecognized))
        XCTAssertEqual(tokenBurn.accounts.first?.plan, .claudeMax5x)
        XCTAssertEqual(tokenBurn.accounts.first?.personalPlanDetected, false)
    }

    /// A personal plan read for the account's
    /// earlier organization proves nothing about its current one.
    func testOnlyTheCurrentOrganizationsPlanProvesOneSeat() async throws {
        let fixture = try makeAlertsFixture()
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let work = try await signIn(fixture, "Work")
        let tokenBurn = tokenBurn(in: fixture.directory)
        fixture.model.tokenBurn = tokenBurn
        await fixture.model.applyDetectedPlan(accountID: work.id, detection: .tier(.claudeMax20x),
                                              at: Date(timeIntervalSince1970: 2_000))
        try await fixture.snapshots.save(UsageSnapshot(
            accountID: work.id, fetchedAt: Date(timeIntervalSince1970: 1_000), fiveHour: nil, weekly: nil,
            organizationID: "org-Team", planDetection: nil))
        XCTAssertEqual(tokenBurn.accounts.first?.organizationID, "org-Team")
        XCTAssertEqual(tokenBurn.accounts.first?.personalPlanDetected, false)
    }
}
