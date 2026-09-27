import XCTest
@testable import Ration

final class APISpendModelEditsTests: APISpendModelTestCase {
    func testAddTrimsPastedKey() async throws {
        let model = makeModel()
        await model.start()
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "0", fetchedAt: now))]
        let id = try await model.addOrg(label: "", rawKey: " sk-ant-admin01-SENTINELSENTINEL\n", budgetCents: nil)
        XCTAssertEqual(try keys.read(for: id), "sk-ant-admin01-SENTINELSENTINEL")
        XCTAssertEqual(model.state.orgs.first?.label, "IZZY", "empty label takes the org name from /me")
        XCTAssertEqual(model.state.orgs.first?.vendorOrgID, "org-1")
    }

    func testAddRefusesRegularKeysAndDuplicates() async throws {
        _ = try await seedOrg()
        let model = makeModel()
        await model.start()
        await assertThrows(try await model.addOrg(label: "x", rawKey: "sk-ant-api03-SENTINEL", budgetCents: nil), .regularKey(.anthropic))
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "0", fetchedAt: now))]
        await assertThrows(try await model.addOrg(label: "x", rawKey: "sk-ant-admin01-OTHERKEY", budgetCents: nil), .duplicate(label: "IZZY"))
        XCTAssertEqual(model.state.orgs.count, 1)
    }

    func testUnchangedBudgetSaveIsANoOp() async throws {
        let id = try await seedOrg(budget: 60_000)
        let model = makeModel()
        await model.start()
        model.injectMemoryForTesting(id, BudgetAlertMemory(evaluatedMonthKey: "2026-09", notifiedTier: .critical, dismissedTier: nil))
        model.setBudget(id, cents: 60_000)
        XCTAssertEqual(model.state.memory[id]?.notifiedTier, .critical)
    }

    func testBudgetChangeClearsTiersKeepsMonthAndEvaluatesImmediately() async throws {
        let id = try await seedOrg(budget: 100_000)
        let model = makeModel()
        await model.start()
        model.injectSnapshotForTesting(id, APISpendSnapshot(cost: costReport(month: UTCMonth(containing: now), cents: "46000", fetchedAt: now.addingTimeInterval(-7_200))))
        model.injectMemoryForTesting(id, BudgetAlertMemory(evaluatedMonthKey: "2026-08", notifiedTier: nil, dismissedTier: nil))
        model.setBudget(id, cents: 60_000)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(bridge.posted, ["\(id.uuidString).budget.2026-09.warning"])
    }

    func testBudgetEditWithoutCurrentReportRecordsNothing() async throws {
        let id = try await seedOrg(budget: 100_000)
        let model = makeModel()
        await model.start()
        model.injectMemoryForTesting(id, BudgetAlertMemory(evaluatedMonthKey: "2026-08", notifiedTier: .warning, dismissedTier: nil))
        model.setBudget(id, cents: 60_000)
        XCTAssertEqual(model.state.memory[id], BudgetAlertMemory(evaluatedMonthKey: "2026-08", notifiedTier: nil, dismissedTier: nil))
        XCTAssertTrue(bridge.decisions.isEmpty)
    }

    func testEditsWhileAlertsOffAreBaselinedOnEnable() async throws {
        let id = try await seedOrg(budget: 100_000)
        bridge.alertsEnabled = false
        let model = makeModel()
        await model.start()
        model.injectSnapshotForTesting(id, APISpendSnapshot(cost: costReport(month: UTCMonth(containing: now), cents: "59000", fetchedAt: now)))
        model.setBudget(id, cents: 60_000)
        bridge.alertsEnabled = true
        bridge.runPrimeHooks()   // enable = OFF→ON activation
        XCTAssertEqual(model.state.memory[id]?.notifiedTier, .critical)
        XCTAssertTrue(bridge.posted.isEmpty)
    }

    func testLoweringThresholdPostsImmediately() async throws {
        let id = try await seedOrg(budget: 60_000)
        let model = makeModel()
        await model.start()
        model.injectSnapshotForTesting(id, APISpendSnapshot(cost: costReport(month: UTCMonth(containing: now), cents: "36000", fetchedAt: now)))
        model.setThresholds(ThresholdPair(warningPercent: 50, criticalPercent: 90))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(bridge.posted, ["\(id.uuidString).budget.2026-09.warning"])
        XCTAssertEqual(model.state.thresholds.warningPercent, 50)
    }

    func testReplaceIsOneAtATimeAndStaleTokenNeverClears() async throws {
        let id = try await seedOrg()
        let model = makeModel()
        await model.start()
        anthropic.suspendNextCost = true
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "0", fetchedAt: now))]
        let first = Task { try await model.replaceKey(id, rawKey: "sk-ant-admin01-NEWKEYNEWKEY") }
        await anthropic.waitUntilCostSuspended()
        await assertThrows(try await model.replaceKey(id, rawKey: "sk-ant-admin01-OTHER"), .busy)
        anthropic.releaseCost()
        try await first.value
        XCTAssertEqual(try keys.read(for: id), "sk-ant-admin01-NEWKEYNEWKEY")
        XCTAssertNil(model.replacing[id])
    }

    func testReplaceWithAnotherOrgsKeyIsRefused() async throws {
        let id = try await seedOrg()
        let model = makeModel()
        await model.start()
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "0", fetchedAt: now))]
        anthropic.identityResult = .success(OrgIdentity(id: "org-OTHER", name: nil))
        await assertThrows(try await model.replaceKey(id, rawKey: "sk-ant-admin01-NEWKEY"), .identityMismatch)
        XCTAssertEqual(try keys.read(for: id), "sk-ant-admin01-SENTINELSENTINEL")
        XCTAssertNil(model.replacing[id])
    }

    func testRemoveRecordFirstKeychainLastIdempotent() async throws {
        let id = try await seedOrg()
        let model = makeModel()
        await model.start()
        keys.failNext[.delete] = .keychain(status: errSecInteractionNotAllowed)
        let removed = await model.removeOrg(id)
        XCTAssertTrue(removed)
        XCTAssertNil(model.org(id))
        XCTAssertTrue(model.hasPendingKeyDeletions)
        await model.retryPendingKeyDeletions()
        XCTAssertFalse(model.hasPendingKeyDeletions)
        XCTAssertThrowsError(try keys.read(for: id))
    }

    func testPendingDeletionOfALiveOrgNeverDeletesItsKey() async throws {
        let id = try await seedOrg()
        let model = makeModel()
        await model.start()
        model.mutateState { $0.pendingKeyDeletions = [id] }
        await model.retryPendingKeyDeletions()
        XCTAssertEqual(try keys.read(for: id), "sk-ant-admin01-SENTINELSENTINEL")
        XCTAssertFalse(model.hasPendingKeyDeletions)
    }

    func testRemoveWhoseStateWriteFailsRestoresTheOrg() async throws {
        let id = try await seedOrg()
        let failWrites = FailSwitch()
        let persistence = APISpendPersistence(
            stateURL: dir.appending(path: "api-spend.json"), snapshotsURL: dir.appending(path: "api-spend-snapshots.json"),
            writeData: { data, url in
                if failWrites.isOn && url.lastPathComponent == "api-spend.json" { throw CocoaError(.fileWriteNoPermission) }
                try data.write(to: url, options: .atomic)
            })
        let model = APISpendModel(dependencies: .init(clients: [.anthropic: anthropic], keyStore: keys, persistence: persistence,
                                                      now: { [unowned self] in self.now }, lowPowerMode: { false }, jitter: { 0 }, autoPoll: false),
                                  settings: settings)
        model.bridge = bridge
        await model.start()
        failWrites.isOn = true
        let removed = await model.removeOrg(id)
        XCTAssertFalse(removed)
        XCTAssertNotNil(model.org(id))
        XCTAssertTrue(model.removeFailures.contains(id))
        XCTAssertFalse(model.hasPendingKeyDeletions)
        XCTAssertEqual(try keys.read(for: id), "sk-ant-admin01-SENTINELSENTINEL")
    }

    private func assertThrows<T>(_ body: @autoclosure () async throws -> T, _ expected: APIOrgEditError, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await body(); XCTFail("expected \(expected)", file: file, line: line) } catch {
            XCTAssertEqual(error as? APIOrgEditError, expected, file: file, line: line)
        }
    }
}

final class FailSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool {
        get { lock.withLock { on } }
        set { lock.withLock { on = newValue } }
    }
}
