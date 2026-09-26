import XCTest
@testable import Ration

/// Records each requested throttle delay and holds the sleeper until the test
/// releases it, so the trailing bump fires exactly when the test says.
actor RevisionSleepGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requested: [TimeInterval] = []

    func sleep(_ seconds: TimeInterval) async {
        requested.append(seconds)
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Waits (bounded) until `count` sleeps have been requested and are held.
    func waitForSleepers(_ count: Int) async {
        for _ in 0..<400 where waiters.count < count {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    func releaseAll() {
        let pending = waiters
        waiters = []
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// A clock the tests move by hand.
@MainActor
final class RevisionTestClock {
    var now: Date
    init(_ seconds: TimeInterval) { now = Date(timeIntervalSince1970: seconds) }
    func set(_ seconds: TimeInterval) { now = Date(timeIntervalSince1970: seconds) }
}

/// `historyRevision` moves on rollup writes, at most once per throttle
/// interval — a leading bump, then one coalesced trailing bump.
@MainActor
final class UsageHistoryRevisionTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = try makeTemporaryDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func account() -> AccountRecord {
        AccountRecord(id: UUID(), provider: .claude, label: "A", webProfileID: UUID(),
                      displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0))
    }

    private func snapshot(_ id: UUID, _ t: TimeInterval, five: Double) -> UsageSnapshot {
        UsageSnapshot(accountID: id, fetchedAt: Date(timeIntervalSince1970: t),
                      fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: five, resetsAt: nil), weekly: nil)
    }

    private func makeStore(clock: RevisionTestClock, gate: RevisionSleepGate) -> UsageHistoryStore {
        UsageHistoryStore(
            rootDirectory: directory,
            timeZone: TimeZone(identifier: "UTC")!,
            now: { clock.now },
            revisionThrottle: 60,
            revisionSleep: { seconds in await gate.sleep(seconds) }
        )
    }

    private func waitForRevision(_ store: UsageHistoryStore, _ expected: Int) async throws {
        for _ in 0..<200 where store.historyRevision < expected {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    func testStartsAtZeroAndTheFirstRollupWriteBumpsAtOnce() async {
        let clock = RevisionTestClock(1_000)
        let gate = RevisionSleepGate()
        let store = makeStore(clock: clock, gate: gate)
        let acc = account()
        await store.load(activeAccountIDs: [acc.id])
        XCTAssertEqual(store.historyRevision, 0)
        store.record(account: acc, snapshot: snapshot(acc.id, 1_000, five: 0.9))
        XCTAssertEqual(store.historyRevision, 1)
        let requested = await gate.requested
        XCTAssertEqual(requested, [], "a leading bump needs no timer")
    }

    /// Several writes inside one minute reload once more, not once each: one
    /// trailing bump, timed for the end of the throttle interval.
    func testWritesWithinTheIntervalCoalesceIntoOneTrailingBump() async throws {
        let clock = RevisionTestClock(1_000)
        let gate = RevisionSleepGate()
        let store = makeStore(clock: clock, gate: gate)
        let a = account()
        let b = account()
        await store.load(activeAccountIDs: [a.id, b.id])
        store.record(account: a, snapshot: snapshot(a.id, 1_000, five: 0.9))
        XCTAssertEqual(store.historyRevision, 1)

        clock.set(1_010)
        store.record(account: b, snapshot: snapshot(b.id, 1_010, five: 0.9))
        clock.set(1_020)
        store.record(account: a, snapshot: snapshot(a.id, 1_020, five: 0.8))
        XCTAssertEqual(store.historyRevision, 1, "writes inside the interval must not bump at once")

        await gate.waitForSleepers(1)
        let requested = await gate.requested
        XCTAssertEqual(requested, [50], "one trailing bump, due 60 s after the leading one")

        await gate.releaseAll()
        try await waitForRevision(store, 2)
        XCTAssertEqual(store.historyRevision, 2)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(store.historyRevision, 2, "the coalesced writes bump exactly once")
    }

    func testAWriteAfterTheIntervalBumpsAtOnce() async {
        let clock = RevisionTestClock(1_000)
        let gate = RevisionSleepGate()
        let store = makeStore(clock: clock, gate: gate)
        let acc = account()
        await store.load(activeAccountIDs: [acc.id])
        store.record(account: acc, snapshot: snapshot(acc.id, 1_000, five: 0.9))
        clock.set(1_060)
        store.record(account: acc, snapshot: snapshot(acc.id, 1_060, five: 0.8))
        XCTAssertEqual(store.historyRevision, 2)
        let requested = await gate.requested
        XCTAssertEqual(requested, [])
    }

    /// A snapshot that writes no rollup (no windows) is not a history change.
    func testASnapshotThatWritesNoRollupDoesNotBump() async {
        let clock = RevisionTestClock(1_000)
        let gate = RevisionSleepGate()
        let store = makeStore(clock: clock, gate: gate)
        let acc = account()
        await store.load(activeAccountIDs: [acc.id])
        let empty = UsageSnapshot(accountID: acc.id, fetchedAt: Date(timeIntervalSince1970: 1_000),
                                  fiveHour: nil, weekly: nil)
        store.record(account: acc, snapshot: empty)
        XCTAssertEqual(store.historyRevision, 0)
    }

    /// A wall clock stepped backwards must not stretch the wait beyond one interval.
    func testTheTrailingDelayNeverExceedsTheInterval() async throws {
        let clock = RevisionTestClock(1_000)
        let gate = RevisionSleepGate()
        let store = makeStore(clock: clock, gate: gate)
        let acc = account()
        await store.load(activeAccountIDs: [acc.id])
        store.record(account: acc, snapshot: snapshot(acc.id, 1_000, five: 0.9))
        clock.set(900)
        store.record(account: acc, snapshot: snapshot(acc.id, 1_300, five: 0.8))
        await gate.waitForSleepers(1)
        let requested = await gate.requested
        XCTAssertEqual(requested, [60])
        await gate.releaseAll()
    }

    func testTheProductionThrottleIsOneMinute() {
        XCTAssertEqual(UsageHistoryStore.defaultRevisionThrottle, 60)
    }
}
