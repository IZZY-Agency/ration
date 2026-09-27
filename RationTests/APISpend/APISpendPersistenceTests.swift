import XCTest
@testable import Ration

@MainActor
final class APISpendPersistenceTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor private final class LiveBox { var state = APISpendState() }

    func testStateRoundTripsAsOneFile() async throws {
        let dir = try directory()
        let persistence = APISpendPersistence(stateURL: dir.appending(path: "api-spend.json"), snapshotsURL: dir.appending(path: "api-spend-snapshots.json"))
        var state = APISpendState()
        let id = UUID()
        state.orgs = [APIOrgRecord(id: id, vendor: .anthropic, vendorOrgID: "org-1", label: "IZZY", monthlyBudgetCents: 60_000, isPaused: false, displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0))]
        state.memory[id] = BudgetAlertMemory(evaluatedMonthKey: "2026-09", notifiedTier: .warning, dismissedTier: nil)
        state.pendingKeyDeletions = [UUID()]
        let snapshot = state
        let outcome = await persistence.writeState { snapshot }
        XCTAssertEqual(outcome, .written)
        let loaded = try await persistence.loadState()
        XCTAssertEqual(loaded, state)
    }

    func testWritesEncodeTheLiveValueAtExecutionTime() async throws {
        let dir = try directory()
        let persistence = APISpendPersistence(stateURL: dir.appending(path: "api-spend.json"), snapshotsURL: dir.appending(path: "s.json"))
        let box = LiveBox()
        let write = Task { await persistence.writeState { box.state } }
        box.state.thresholds = ThresholdPair(warningPercent: 60, criticalPercent: 80)   // before the queued write runs
        _ = await write.value
        let loaded = try await persistence.loadState()
        XCTAssertEqual(loaded.thresholds.warningPercent, 60)
    }

    func testFailedWriteReportsFailed() async throws {
        let dir = try directory()
        let persistence = APISpendPersistence(stateURL: dir.appending(path: "api-spend.json"), snapshotsURL: dir.appending(path: "s.json"), writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        let outcome = await persistence.writeState { APISpendState() }
        XCTAssertEqual(outcome, .failed)
    }

    func testNilLiveValueIsStale() async throws {
        let dir = try directory()
        let persistence = APISpendPersistence(stateURL: dir.appending(path: "api-spend.json"), snapshotsURL: dir.appending(path: "s.json"))
        let outcome = await persistence.writeState { nil }
        XCTAssertEqual(outcome, .stale)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appending(path: "api-spend.json").path))
    }

    func testMissingFileLoadsEmptyState() async throws {
        let dir = try directory()
        let persistence = APISpendPersistence(stateURL: dir.appending(path: "absent.json"), snapshotsURL: dir.appending(path: "s.json"))
        let loaded = try await persistence.loadState()
        XCTAssertEqual(loaded, APISpendState())
    }

    func testSnapshotsRoundTripAndUnreadableCacheIsEmpty() async throws {
        let dir = try directory()
        let url = dir.appending(path: "s.json")
        let persistence = APISpendPersistence(stateURL: dir.appending(path: "a.json"), snapshotsURL: url)
        let id = UUID()
        let month = UTCMonth(year: 2026, month: 9)
        let snaps = [id: APISpendSnapshot(cost: APICostReport(month: month, fetchedAt: month.start, refreshStartedAt: month.start, days: [DayCost(dayStart: month.start, cents: Decimal(string: "1.5")!)], byModel: [], otherCharges: [], byLineItem: []), tokens: nil, priorityPresentMonth: nil)]
        let outcome = await persistence.writeSnapshots { snaps }
        XCTAssertEqual(outcome, .written)
        let loaded = await persistence.loadSnapshots()
        XCTAssertEqual(loaded, snaps)
        try Data("garbage".utf8).write(to: url)
        let garbage = await persistence.loadSnapshots()
        XCTAssertEqual(garbage, [:])
    }
}
