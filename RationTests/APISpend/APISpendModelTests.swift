import XCTest
@testable import Ration

final class APISpendModelTests: APISpendModelTestCase {
    func testFreshReportAboveWarningPostsOnce() async throws {
        let id = try await seedOrg()
        let month = UTCMonth(containing: now)
        anthropic.costResults = [.success(costReport(month: month, cents: "46000", fetchedAt: now)), .success(costReport(month: month, cents: "47000", fetchedAt: now))]
        let model = makeModel()
        await model.start()
        await model.refresh(id)
        await Task.yield()
        await model.refresh(id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(bridge.posted, ["\(id.uuidString).budget.2026-09.warning"])
        model.stop()
    }

    func testNotReadyMeansCardsUpdateButNoEvaluation() async throws {
        let id = try await seedOrg()
        bridge.alertsReady = false
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "59000", fetchedAt: now))]
        let model = makeModel()
        await model.start()
        await model.refresh(id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(model.snapshots[id]?.cost)
        XCTAssertTrue(bridge.decisions.isEmpty)
        XCTAssertNil(model.state.memory[id]?.notifiedTier)
        model.stop()
    }

    func testOldMonthReportIsNotCurrentAndNotEvaluated() async throws {
        let id = try await seedOrg()
        let august = UTCMonth(year: 2026, month: 8)
        anthropic.costResults = [.success(costReport(month: august, cents: "59000", fetchedAt: august.start))]
        let model = makeModel()
        await model.start()
        await model.refresh(id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(bridge.decisions.isEmpty)
        XCTAssertTrue(model.presentations(now: now).first?.isOldMonth ?? false)
    }

    func testSuspendedFetchAfterPauseCommitsNothing() async throws {
        let id = try await seedOrg()
        anthropic.suspendNextCost = true
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "59000", fetchedAt: now))]
        let model = makeModel()
        await model.start()
        let fetch = Task { await model.refresh(id) }
        await anthropic.waitUntilCostSuspended()
        await model.setPaused(id, true)
        anthropic.releaseCost()
        await fetch.value
        XCTAssertNil(model.snapshots[id]?.cost)
        XCTAssertTrue(bridge.decisions.isEmpty)
    }

    func testTokenFailureLeavesCostAndAlertsIntact() async throws {
        let id = try await seedOrg()
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "46000", fetchedAt: now))]
        anthropic.tokenResults = [.failure(.server(status: 500))]
        let model = makeModel()
        await model.start()
        await model.refresh(id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNotNil(model.snapshots[id]?.cost)
        XCTAssertEqual(model.tokenErrors[id], .server(status: 500))
        XCTAssertEqual(bridge.posted.count, 1)
    }

    func testPrimeRecordsCurrentTierWithoutPostingAndIncludesPaused() async throws {
        let id = try await seedOrg(paused: true)
        let model = makeModel()
        await model.start()
        model.injectSnapshotForTesting(id, APISpendSnapshot(cost: costReport(month: UTCMonth(containing: now), cents: "59000", fetchedAt: now)))
        bridge.runPrimeHooks()
        XCTAssertEqual(model.state.memory[id]?.notifiedTier, .critical)
        XCTAssertTrue(bridge.posted.isEmpty)
    }

    func testMonthAdvanceLiftsSnoozeWhenDropChannelOn() async throws {
        let id = try await seedOrg()
        let model = makeModel()
        await model.start()
        model.injectMemoryForTesting(id, BudgetAlertMemory(evaluatedMonthKey: "2026-08", notifiedTier: .critical, dismissedTier: nil))
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "1", fetchedAt: now))]
        await model.refresh(id)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(bridge.snoozeLifts, 1)
    }

    func testRateLimitHoldsRefreshUntilRetryAfter() async throws {
        let id = try await seedOrg()
        anthropic.costResults = [.failure(.rateLimited(retryAt: now.addingTimeInterval(600)))]
        let model = makeModel()
        await model.start()
        await model.refresh(id)
        await model.refresh(id)
        XCTAssertEqual(anthropic.costCalls, 1)
        XCTAssertEqual(model.costErrors[id], .rateLimited(retryAt: now.addingTimeInterval(600)))
    }

    /// The unit-test host (unsandboxed, a different state file with no orgs)
    /// shares the Keychain and would see the app's keys as "orphans" and
    /// delete them. A key is deleted ONLY when this state journaled its
    /// removal — never because some state file lacks its org.
    func testStartupNeverDeletesKeysItDidNotJournal() async throws {
        let id = try await seedOrg()
        let foreign = UUID()
        keys.seed("sk-ant-admin01-FOREIGNFOREIGN", for: foreign)
        let model = makeModel()
        await model.start()
        await model.retryPendingKeyDeletions()
        XCTAssertEqual(try keys.read(for: id), "sk-ant-admin01-SENTINELSENTINEL")
        XCTAssertEqual(try keys.read(for: foreign), "sk-ant-admin01-FOREIGNFOREIGN", "a key another state owns is never touched")
        XCTAssertFalse(model.state.pendingKeyDeletions.contains(foreign))
        XCTAssertTrue(keys.deleted.isEmpty)
    }
}
