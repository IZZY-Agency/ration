import XCTest
@testable import Ration

/// Regression tests for API spend edits, alerts and fetches.
@MainActor
final class APISpendModelSafetyTests: APISpendModelTestCase {
    private let sentinel = "sk-ant-admin01-SENTINELSENTINEL"

    private func makeModel(failWrites: FailSwitch) -> APISpendModel {
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
        return model
    }

    /// The cleanup tick must not delete a key whose removal is still
    /// being written — the write can fail and restore the org.
    func testCleanupDuringAFailingRemovalKeepsTheKey() async throws {
        let id = try await seedOrg()
        let failWrites = FailSwitch()
        let model = makeModel(failWrites: failWrites)
        await model.start()
        failWrites.isOn = true
        let removal = Task { await model.removeOrg(id) }
        await Task.yield()
        XCTAssertTrue(model.hasPendingKeyDeletions, "the removal is mid-write")
        await model.retryPendingKeyDeletions()
        let removed = await removal.value
        XCTAssertFalse(removed)
        XCTAssertNotNil(model.org(id))
        XCTAssertEqual(try keys.read(for: id), sentinel)
    }

    /// A queued alert whose tier the thresholds no longer reach never posts.
    func testSupersededThresholdNeverNotifies() async throws {
        let id = try await seedOrg(budget: 10_000)
        let model = makeModel()
        await model.start()
        model.injectSnapshotForTesting(id, APISpendSnapshot(cost: costReport(month: UTCMonth(containing: now), cents: "6000", fetchedAt: now)))
        model.setThresholds(ThresholdPair(warningPercent: 50, criticalPercent: 90))
        model.setThresholds(ThresholdPair(warningPercent: 90, criticalPercent: 95))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(bridge.posted.isEmpty, "60 % no longer reaches warning (90 %)")
    }

    /// Counterpart: lowered twice, the crossing is still true → it posts.
    func testThresholdLoweredTwiceStillNotifiesOnce() async throws {
        let id = try await seedOrg(budget: 10_000)
        let model = makeModel()
        await model.start()
        model.injectSnapshotForTesting(id, APISpendSnapshot(cost: costReport(month: UTCMonth(containing: now), cents: "6000", fetchedAt: now)))
        model.setThresholds(ThresholdPair(warningPercent: 50, criticalPercent: 90))
        model.setThresholds(ThresholdPair(warningPercent: 40, criticalPercent: 90))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(bridge.posted, ["\(id.uuidString).budget.2026-09.warning"])
    }

    /// The fetch carries a "still wanted" check that pausing turns off,
    /// so paging stops before the next request with the key.
    func testFetchScopeTurnsFalseWhenTheOrgIsPaused() async throws {
        let id = try await seedOrg()
        let model = makeModel()
        await model.start()
        anthropic.suspendNextCost = true
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "0", fetchedAt: now))]
        let refresh = Task { await model.refresh(id) }
        await anthropic.waitUntilCostSuspended()
        let scope = try XCTUnwrap(anthropic.lastScope, "fetchOnce runs the client inside APISpendFetchScope")
        let wantedBefore = await scope()
        XCTAssertTrue(wantedBefore)
        await model.setPaused(id, true)
        let wantedAfter = await scope()
        XCTAssertFalse(wantedAfter)
        anthropic.releaseCost()
        await refresh.value
    }

    /// Cancel during validation never stores the key or the org.
    func testCancelledAddNeverStoresTheKey() async throws {
        let model = makeModel()
        await model.start()
        anthropic.suspendNextCost = true
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "0", fetchedAt: now))]
        let add = Task { try await model.addOrg(label: "x", rawKey: sentinel, budgetCents: nil) }
        await anthropic.waitUntilCostSuspended()
        add.cancel()
        anthropic.releaseCost()
        do { _ = try await add.value; XCTFail("expected cancellation") } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(model.state.orgs.isEmpty)
        XCTAssertTrue(try keys.allOrgIDs().isEmpty)
    }

    /// Cancel during a replacement keeps the old key and frees the org.
    func testCancelledReplaceKeepsTheOldKey() async throws {
        let id = try await seedOrg()
        let model = makeModel()
        await model.start()
        anthropic.suspendNextCost = true
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "0", fetchedAt: now))]
        let replace = Task { try await model.replaceKey(id, rawKey: "sk-ant-admin01-NEWKEYNEWKEY") }
        await anthropic.waitUntilCostSuspended()
        replace.cancel()
        anthropic.releaseCost()
        do { try await replace.value; XCTFail("expected cancellation") } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(try keys.read(for: id), sentinel)
        XCTAssertNil(model.replacing[id])
    }

    /// A quit flushes API edits like any other Settings edit.
    func testQuitFlushCoversAPIStateWrites() async throws {
        let id = try await seedOrg()
        let model = makeModel()
        await model.start()
        let registry = PendingEditRegistry()
        registry.register(model, key: APISpendModel.pendingEditKey)
        _ = await registry.flushAll()   // start()'s reconcile queues a write of its own
        XCTAssertFalse(registry.hasPendingEdits)
        model.setBudget(id, cents: 70_000)
        XCTAssertTrue(registry.hasPendingEdits, "the budget write is queued")
        let flushed = await registry.flushAll()
        XCTAssertTrue(flushed)
        XCTAssertFalse(registry.hasPendingEdits)
        let persistence = APISpendPersistence(stateURL: dir.appending(path: "api-spend.json"), snapshotsURL: dir.appending(path: "api-spend-snapshots.json"))
        let onDisk = try await persistence.loadState()
        XCTAssertEqual(onDisk.orgs.first?.monthlyBudgetCents, 70_000)
    }

    /// The combined Settings order is saved with the API state, and the API
    /// accounts' own order (popover cards, gauges) follows it.
    func testSidebarOrderPersistsAndDrivesTheAPIOrder() async throws {
        let first = try await seedOrg()
        let model = makeModel()
        await model.start()
        let second = UUID(), subscription = UUID()
        model.mutateState { state in
            state.orgs.append(APIOrgRecord(id: second, vendor: .openAI, vendorOrgID: "org-o", label: "OpenAI", monthlyBudgetCents: nil,
                                           isPaused: false, displayOrder: 1, createdAt: self.now))
        }
        model.setSidebarOrder([.api(second), .subscription(subscription), .api(first)])
        XCTAssertEqual(model.presentations(now: now).map(\.id), [second, first])
        XCTAssertEqual(model.state.sidebarOrder, [second, subscription, first])
        await model.flushPendingEdit()
        let onDisk = try await APISpendPersistence(stateURL: dir.appending(path: "api-spend.json"),
                                                   snapshotsURL: dir.appending(path: "api-spend-snapshots.json")).loadState()
        XCTAssertEqual(onDisk.sidebarOrder, [second, subscription, first])
    }

    /// Recovery path: Replace on an account whose key is
    /// gone from the Keychain stores the new key (it used to fail).
    func testReplaceRestoresAMissingKey() async throws {
        let id = try await seedOrg()
        let model = makeModel()
        await model.start()
        try keys.delete(for: id)
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "0", fetchedAt: now)),
                                 .success(costReport(month: UTCMonth(containing: now), cents: "0", fetchedAt: now))]
        try await model.replaceKey(id, rawKey: "sk-ant-admin01-RESTOREDRESTORED")
        XCTAssertEqual(try keys.read(for: id), "sk-ant-admin01-RESTOREDRESTORED")
        XCTAssertNil(model.costErrors[id], "no longer keyMissing")
    }

    /// The app skips the API spend start inside the unit-test host.
    func testUnitTestHostIsDetected() {
        XCTAssertTrue(RuntimeEnvironment.isHostingUnitTests)
    }

    /// A replacement and a removal never overlap on one org —
    /// otherwise a late Replace could re-add a key after Remove deleted it,
    /// leaving an Admin key in the Keychain with no account.
    func testRemoveIsRefusedWhileAReplacementRuns() async throws {
        let id = try await seedOrg()
        let model = makeModel()
        await model.start()
        anthropic.suspendNextCost = true
        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "0", fetchedAt: now)),
                                 .success(costReport(month: UTCMonth(containing: now), cents: "0", fetchedAt: now))]
        let replace = Task { try await model.replaceKey(id, rawKey: "sk-ant-admin01-NEWKEYNEWKEY") }
        await anthropic.waitUntilCostSuspended()
        let removed = await model.removeOrg(id)
        XCTAssertFalse(removed, "refused while the replacement runs")
        XCTAssertNotNil(model.org(id))
        XCTAssertFalse(model.removeFailures.contains(id), "a refusal is not a failed removal")
        anthropic.releaseCost()
        try await replace.value
        XCTAssertEqual(try keys.read(for: id), "sk-ant-admin01-NEWKEYNEWKEY")
    }

    func testReplaceIsRefusedWhileARemovalRuns() async throws {
        let id = try await seedOrg()
        let failWrites = FailSwitch()
        let model = makeModel(failWrites: failWrites)
        await model.start()
        let removal = Task { await model.removeOrg(id) }
        await Task.yield()   // the removal is mid-write
        do {
            try await model.replaceKey(id, rawKey: "sk-ant-admin01-NEWKEYNEWKEY")
            XCTFail("expected busy")
        } catch {
            XCTAssertEqual(error as? APIOrgEditError, .busy)
        }
        _ = await removal.value
    }

    /// A key missing from the Keychain is not read again on every refresh:
    /// nothing can change until the user replaces it, and each try logged.
    func testAMissingKeyIsNotRetriedUntilItIsReplaced() async throws {
        let id = try await seedOrg()
        let model = makeModel()
        await model.start()
        try keys.delete(for: id)
        let before = keys.reads
        await model.refresh(id)
        XCTAssertEqual(model.costErrors[id], .keyMissing)
        XCTAssertEqual(keys.reads, before + 1)
        await model.refresh(id)
        await model.refreshAll()
        XCTAssertEqual(keys.reads, before + 1, "not retried while the key is missing")

        anthropic.costResults = [.success(costReport(month: UTCMonth(containing: now), cents: "0", fetchedAt: now)),
                                 .success(costReport(month: UTCMonth(containing: now), cents: "100", fetchedAt: now))]
        try await model.replaceKey(id, rawKey: "sk-ant-admin01-RESTOREDRESTORED")
        XCTAssertNil(model.costErrors[id], "Replace clears it and refreshes")
        XCTAssertEqual(model.snapshots[id]?.cost?.monthToDateCents, 100)
    }
}
