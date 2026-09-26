import WebKit
import XCTest
@testable import Ration

/// Cursor spend history through `AppModel`: the background backfill after a
/// poll, fail-closed retries, the rollover append, and removal.
@MainActor
final class AppModelCursorHistoryTests: XCTestCase {
    static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    final class Clock {
        var now: Date
        init(_ now: Date) { self.now = now }
    }

    struct Fixture {
        let directory: URL
        let model: AppModel
        let adapter: CursorHistoryAdapterSpy
        let store: CursorSpendHistoryStore
        let clock: Clock

        var historyFile: URL { directory.appending(path: "cursor-spend-history.json") }

        func removeFiles() {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func makeFixture(
        directory: URL? = nil,
        now: Date = date("2026-09-10T12:00:00Z"),
        saveFails: FailingSave? = nil
    ) throws -> Fixture {
        let directory = try directory ?? makeTempDirectory()
        let clock = Clock(now)
        let adapter = CursorHistoryAdapterSpy(periodStart: Self.date("2026-09-01T00:00:00Z"))
        let fileURL = directory.appending(path: "cursor-spend-history.json")
        let fileStore = JSONFileStore<[UUID: CursorSpendHistory]>(fileURL: fileURL, defaultValue: [:])
        struct SaveFailed: Error {}
        let store = CursorSpendHistoryStore(fileURL: fileURL, saveHistories: { histories in
            if let saveFails, saveFails.fails {
                throw SaveFailed()
            }
            try await fileStore.save(histories)
        })
        let model = AppModel(
            accountStore: AccountStore(fileURL: directory.appending(path: "accounts.json")),
            snapshotStore: UsageSnapshotStore(fileURL: directory.appending(path: "snapshots.json")),
            pendingProfileDeletionStore: PendingProfileDeletionStore(
                fileURL: directory.appending(path: "pending-profile-deletions.json")
            ),
            historyStore: UsageHistoryStore(rootDirectory: directory.appending(path: "history", directoryHint: .isDirectory)),
            appSettings: AppSettings(fileURL: directory.appending(path: "app-settings.json")),
            alertStateStore: AlertStateStore(fileURL: directory.appending(path: "alert-state.json")),
            cursorSpendHistoryStore: store,
            profileManager: AlertsWebProfileManagerSpy(),
            adapterRegistry: ProviderAdapterRegistry(adapters: [adapter]),
            notificationScheduler: NotificationSchedulingSpy(),
            now: { clock.now },
            systemPowerObserver: NoopSystemPowerObserver()
        )
        return Fixture(directory: directory, model: model, adapter: adapter, store: store, clock: clock)
    }

    func signIn(_ fixture: Fixture) async throws -> UUID {
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .cursor)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Team")
        await fixture.model.refreshAll()
        await fixture.model.flushCursorHistoryRefreshes()
        return try XCTUnwrap(fixture.model.accounts.last).id
    }

    /// Yields until the adapter has seen `count` history reads (the read
    /// starts after the attempt is recorded, a few hops after the poll).
    private func waitForHistoryRequests(_ fixture: Fixture, count: Int) async {
        for _ in 0..<10_000 where fixture.adapter.historyRequests.count < count {
            await Task.yield()
        }
    }

    static func cycle(_ start: String, _ end: String, _ cents: Int) -> CursorSpendCycle {
        CursorSpendCycle(periodStart: date(start), periodEnd: date(end), spentCents: cents, isClosed: true)
    }

    let august = cycle("2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z", 2410)
    private let july = cycle("2026-07-01T00:00:00Z", "2026-08-01T00:00:00Z", 3410)
    private let september = cycle("2026-09-01T00:00:00Z", "2026-10-01T00:00:00Z", 4120)

    // MARK: - Backfill

    /// Twelve closed months before `open`, as a complete (exhausted) walk
    /// returns them.
    static func fullYear(before open: String, cents: Int = 100) -> CursorHistoryFetch {
        var cycles: [CursorSpendCycle] = []
        for month in CursorSpendHistoryPlanner.months(before: date(open), count: 12).reversed() {
            let start = CursorSpendHistoryPlanner.start(of: month)
            let end = CursorSpendHistoryPlanner.start(of: CursorSpendHistoryPlanner.next(month))
            cycles.append(CursorSpendCycle(periodStart: start, periodEnd: end, spentCents: cents, isClosed: true))
        }
        return CursorHistoryFetch(cycles: cycles, historyExhausted: true, oldestEventAt: date("2024-01-01T00:00:00Z"))
    }

    /// The poll that triggers the backfill does not wait for it: the snapshot
    /// is saved while the history read is still suspended.
    func testBackfillRunsInTheBackgroundAfterThePoll() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.historyResult = .failure(ProviderError.transport)
        let id = try await signIn(fixture)
        let firstRequests = fixture.adapter.historyRequests.count

        fixture.clock.now = Self.date("2026-09-11T12:00:00Z")
        fixture.adapter.holdsHistory = true
        let year = Self.fullYear(before: "2026-09-01T00:00:00Z")
        fixture.adapter.historyResult = .success(year)
        await fixture.model.refreshAll()
        XCTAssertNotNil(fixture.model.snapshot(for: id)?.cursorSpend, "the poll landed")
        await waitForHistoryRequests(fixture, count: firstRequests + 1)
        XCTAssertEqual(fixture.adapter.historyRequests.count, firstRequests + 1, "the read has started…")
        XCTAssertEqual(fixture.model.cursorSpendCycles(for: id), [], "…and is still pending")

        fixture.adapter.releaseHistory()
        await fixture.model.flushCursorHistoryRefreshes()
        XCTAssertEqual(fixture.model.cursorSpendCycles(for: id), year.cycles)
        let request = try XCTUnwrap(fixture.adapter.historyRequests.last)
        XCTAssertEqual(request.months.count, 12, "the one-time backfill asks for twelve cycles")
        XCTAssertEqual(request.months.first, CursorInvoiceMonth(year: 2026, month: 7))
        XCTAssertEqual(fixture.store.history(for: id).syncedThrough, Self.date("2026-09-01T00:00:00Z"))

        // Done once: later polls this cycle read nothing more.
        fixture.clock.now = Self.date("2026-09-20T12:00:00Z")
        await fixture.model.refreshAll()
        await fixture.model.flushCursorHistoryRefreshes()
        XCTAssertEqual(fixture.adapter.historyRequests.count, firstRequests + 1)
    }

    /// A read that fails closed leaves the cycles as they were and is retried
    /// on a later day — not on every poll.
    func testFailedBackfillLeavesHistoryUnchangedAndRetriesOnALaterDay() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.historyResult = .failure(ProviderError.integrationChanged)
        let id = try await signIn(fixture)
        XCTAssertEqual(fixture.adapter.historyRequests.count, 1)
        XCTAssertEqual(fixture.model.cursorSpendCycles(for: id), [])
        XCTAssertNil(fixture.store.history(for: id).syncedThrough)
        XCTAssertEqual(fixture.store.history(for: id).lastAttemptAt, fixture.clock.now)

        fixture.clock.now = Self.date("2026-09-10T20:00:00Z")
        await fixture.model.refreshAll()
        await fixture.model.flushCursorHistoryRefreshes()
        XCTAssertEqual(fixture.adapter.historyRequests.count, 1, "same day: no retry")

        fixture.clock.now = fixture.clock.now.addingTimeInterval(86_400)
        fixture.adapter.historyResult = .success(CursorHistoryFetch(cycles: [august], historyExhausted: false, oldestEventAt: nil))
        await fixture.model.refreshAll()
        await fixture.model.flushCursorHistoryRefreshes()
        XCTAssertEqual(fixture.adapter.historyRequests.count, 2, "a later day: retried")
        XCTAssertEqual(fixture.model.cursorSpendCycles(for: id), [august])
    }

    /// No daily limit can be relied on when the attempt stamp cannot be
    /// saved: the read is skipped rather than repeated on every poll.
    func testUnsavableAttemptStampSkipsTheRead() async throws {
        let failing = FailingSave()
        failing.fails = true
        let fixture = try makeFixture(saveFails: failing)
        defer { fixture.removeFiles() }
        fixture.adapter.historyResult = .success(Self.fullYear(before: "2026-09-01T00:00:00Z"))
        _ = try await signIn(fixture)
        await fixture.model.refreshAll()
        await fixture.model.flushCursorHistoryRefreshes()
        XCTAssertEqual(fixture.adapter.historyRequests.count, 0)
    }

    // MARK: - Rollover

    func testRolloverAppendsTheFinishedCycleExactlyOnce() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        let year = Self.fullYear(before: "2026-09-01T00:00:00Z")
        fixture.adapter.historyResult = .success(year)
        let id = try await signIn(fixture)
        XCTAssertEqual(fixture.model.cursorSpendCycles(for: id), year.cycles)

        // Midnight UTC, 1 October: the poll reports the new cycle.
        fixture.clock.now = Self.date("2026-10-01T00:05:00Z")
        fixture.adapter.periodStart = Self.date("2026-10-01T00:00:00Z")
        fixture.adapter.historyResult = .success(CursorHistoryFetch(cycles: [september], historyExhausted: false, oldestEventAt: nil))
        await fixture.model.refreshAll()
        await fixture.model.flushCursorHistoryRefreshes()
        XCTAssertEqual(fixture.adapter.historyRequests.last?.months, [CursorInvoiceMonth(year: 2026, month: 8)])
        XCTAssertEqual(fixture.model.cursorSpendCycles(for: id).last, september)

        for _ in 0..<3 {
            await fixture.model.refreshAll()
            await fixture.model.flushCursorHistoryRefreshes()
        }
        XCTAssertEqual(fixture.adapter.historyRequests.count, 2, "no second read for the same rollover")
        XCTAssertEqual(fixture.model.cursorSpendCycles(for: id).filter { $0 == september }.count, 1, "appended once")
        XCTAssertEqual(fixture.model.cursorSpendCycles(for: id).count, 12, "the oldest month dropped out of the window")
    }

    // MARK: - Sign-in sessions

    /// An open reauth session shares the account's view: no history read
    /// starts under it (the poll itself is suppressed too), and nothing
    /// of the daily attempt is spent.
    func testNoReadStartsWhileASignInSessionHoldsTheView() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.historyResult = .failure(ProviderError.transport)
        let id = try await signIn(fixture)
        let stamp = fixture.store.history(for: id).lastAttemptAt
        _ = try fixture.model.beginReauthentication(accountID: id)

        fixture.clock.now = Self.date("2026-09-12T12:00:00Z")
        fixture.adapter.historyResult = .success(Self.fullYear(before: "2026-09-01T00:00:00Z"))
        await fixture.model.refreshAll()
        await fixture.model.flushCursorHistoryRefreshes()
        XCTAssertEqual(fixture.adapter.historyRequests.count, 1, "no read while the session is open")
        XCTAssertEqual(fixture.store.history(for: id).lastAttemptAt, stamp, "no attempt spent")
    }

    /// A session opened after the read started, but before its script is
    /// dispatched, vetoes it — and hands the attempt back, so the read runs
    /// on the next poll after the session closes, the same day.
    func testASessionOpenedBeforeDispatchVetoesTheReadWithoutSpendingTheDay() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.historyResult = .failure(ProviderError.transport)
        let id = try await signIn(fixture)
        let stamp = fixture.store.history(for: id).lastAttemptAt

        fixture.clock.now = Self.date("2026-09-12T12:00:00Z")
        fixture.adapter.holdsHistory = true
        let year = Self.fullYear(before: "2026-09-01T00:00:00Z")
        fixture.adapter.historyResult = .success(year)
        await fixture.model.refreshAll()
        await waitForHistoryRequests(fixture, count: 2)
        let sessionID = try fixture.model.beginReauthentication(accountID: id)
        fixture.adapter.releaseHistory()
        await fixture.model.flushCursorHistoryRefreshes()
        XCTAssertEqual(fixture.adapter.vetoedCount, 1)
        XCTAssertEqual(fixture.model.cursorSpendCycles(for: id), [])
        XCTAssertEqual(fixture.store.history(for: id).lastAttemptAt, stamp, "the suppressed attempt is handed back")

        await fixture.model.cancelSignIn(sessionID: sessionID)
        fixture.clock.now = Self.date("2026-09-12T12:10:00Z")
        await fixture.model.refreshAll()
        await fixture.model.flushCursorHistoryRefreshes()
        XCTAssertEqual(fixture.adapter.historyRequests.count, 3, "read again the same day, once the session closed")
        XCTAssertEqual(fixture.model.cursorSpendCycles(for: id), year.cycles)
    }

    // MARK: - Removal

    func testRemovingTheAccountDropsItsHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.historyResult = .success(CursorHistoryFetch(cycles: [august], historyExhausted: false, oldestEventAt: nil))
        let id = try await signIn(fixture)
        XCTAssertEqual(fixture.model.cursorSpendCycles(for: id), [august], "premise")

        try await fixture.model.removeAccount(id: id)
        XCTAssertEqual(fixture.model.cursorSpendCycles(for: id), [])
        XCTAssertNil(fixture.store.histories[id])
        let reloaded = CursorSpendHistoryStore(fileURL: fixture.historyFile)
        await reloaded.load()
        XCTAssertNil(reloaded.histories[id], "gone from the file too")
    }

    /// A delete that fails is kept pending and retried, not swallowed.
    func testFailedHistoryDeletionIsRetried() async throws {
        let failing = FailingSave()
        let fixture = try makeFixture(saveFails: failing)
        defer { fixture.removeFiles() }
        fixture.adapter.historyResult = .success(CursorHistoryFetch(cycles: [august], historyExhausted: false, oldestEventAt: nil))
        let id = try await signIn(fixture)
        XCTAssertEqual(fixture.model.cursorSpendCycles(for: id), [august], "premise")

        failing.fails = true
        try await fixture.model.removeAccount(id: id)
        XCTAssertNotNil(fixture.store.histories[id], "the delete failed…")
        XCTAssertEqual(fixture.model.pendingCursorHistoryRemovals, [id], "…and is pending")

        failing.fails = false
        await fixture.model.retryPendingCursorHistoryRemovals()
        XCTAssertNil(fixture.store.histories[id])
        XCTAssertEqual(fixture.model.pendingCursorHistoryRemovals, [])
    }

    /// A read still in flight when the account is removed lands nowhere.
    func testReadInFlightDuringRemovalDoesNotResurrectTheEntry() async throws {
        let fixture = try makeFixture()
        defer { fixture.removeFiles() }
        fixture.adapter.historyResult = .failure(ProviderError.transport)
        let id = try await signIn(fixture)

        fixture.clock.now = Self.date("2026-09-12T12:00:00Z")
        fixture.adapter.holdsHistory = true
        fixture.adapter.historyResult = .success(CursorHistoryFetch(cycles: [august], historyExhausted: false, oldestEventAt: nil))
        await fixture.model.refreshAll()
        await waitForHistoryRequests(fixture, count: 2)
        let inFlight = try XCTUnwrap(fixture.model.cursorHistoryTaskForTesting(accountID: id))
        try await fixture.model.removeAccount(id: id)
        fixture.adapter.releaseHistory()
        await inFlight.value
        XCTAssertNil(fixture.store.histories[id])
        let reloaded = CursorSpendHistoryStore(fileURL: fixture.historyFile)
        await reloaded.load()
        XCTAssertNil(reloaded.histories[id])
    }

    /// An entry left behind by a removal that never finished is pruned at launch.
    func testOrphanedEntryIsPrunedOnLoad() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphan = UUID()
        let seed = CursorSpendHistoryStore(fileURL: directory.appending(path: "cursor-spend-history.json"))
        try await seed.update(accountID: orphan) { _ in CursorSpendHistory(cycles: [self.august]) }

        let fixture = try makeFixture(directory: directory)
        try await fixture.model.load(startBackgroundRefresh: false)
        XCTAssertNil(fixture.store.histories[orphan])
    }
}

extension AppModelCursorHistoryTests {
    /// The last account goes and its delete fails: no poll is left to retry,
    /// but the recorded deletion is scrubbed on the next launch.
    func testLastAccountRemovalWithAFailedDeleteIsScrubbedOnRelaunch() async throws {
        let failing = FailingSave()
        let fixture = try makeFixture(saveFails: failing)
        fixture.adapter.historyResult = .success(CursorHistoryFetch(cycles: [august], historyExhausted: false, oldestEventAt: nil))
        let id = try await signIn(fixture)
        failing.fails = true
        try await fixture.model.removeAccount(id: id)
        XCTAssertEqual(fixture.model.pendingCursorHistoryRemovals, [id], "premise: the delete failed")

        let relaunch = try makeFixture(directory: fixture.directory)
        defer { relaunch.removeFiles() }
        try await relaunch.model.load(startBackgroundRefresh: false)
        let onDisk = CursorSpendHistoryStore(fileURL: relaunch.historyFile)
        await onDisk.load()
        XCTAssertNil(onDisk.histories[id])
    }

    /// A startup prune whose save fails stays recorded and is retried.
    func testFailedStartupPruneIsRetried() async throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let orphan = UUID()
        let seed = CursorSpendHistoryStore(fileURL: directory.appending(path: "cursor-spend-history.json"))
        try await seed.update(accountID: orphan) { _ in CursorSpendHistory(cycles: [self.august]) }

        let failing = FailingSave()
        failing.fails = true
        let fixture = try makeFixture(directory: directory, saveFails: failing)
        try await fixture.model.load(startBackgroundRefresh: false)
        XCTAssertEqual(fixture.model.pendingCursorHistoryRemovals, [orphan], "premise: the prune failed")

        failing.fails = false
        await fixture.model.retryPendingCursorHistoryRemovals()
        XCTAssertNil(fixture.store.histories[orphan])
        XCTAssertEqual(fixture.model.pendingCursorHistoryRemovals, [])
    }

    /// A sign-in veto whose attempt hand-back fails keeps the hand-back
    /// pending: the same-day retry after the session closes still happens.
    func testFailedAttemptHandBackIsRetriedBeforeTheNextCheck() async throws {
        let failing = FailingSave()
        let fixture = try makeFixture(saveFails: failing)
        defer { fixture.removeFiles() }
        fixture.adapter.historyResult = .failure(ProviderError.transport)
        let id = try await signIn(fixture)

        fixture.clock.now = ISO8601DateFormatter().date(from: "2026-09-12T12:00:00Z")!
        fixture.adapter.holdsHistory = true
        let year = Self.fullYear(before: "2026-09-01T00:00:00Z")
        fixture.adapter.historyResult = .success(year)
        await fixture.model.refreshAll()
        for _ in 0..<10_000 where fixture.adapter.historyRequests.count < 2 {
            await Task.yield()
        }
        let sessionID = try fixture.model.beginReauthentication(accountID: id)
        failing.fails = true
        fixture.adapter.releaseHistory()
        await fixture.model.flushCursorHistoryRefreshes()
        XCTAssertEqual(fixture.adapter.vetoedCount, 1, "premise: vetoed, and the hand-back failed")

        failing.fails = false
        await fixture.model.cancelSignIn(sessionID: sessionID)
        fixture.clock.now = ISO8601DateFormatter().date(from: "2026-09-12T12:10:00Z")!
        await fixture.model.refreshAll()
        await fixture.model.flushCursorHistoryRefreshes()
        XCTAssertEqual(fixture.adapter.historyRequests.count, 3, "retried the same day")
        XCTAssertEqual(fixture.model.cursorSpendCycles(for: id), year.cycles)
    }
}

/// Makes the history store's saves fail on demand.
@MainActor
final class FailingSave {
    var fails = false
}

/// A Cursor adapter whose usage fetch reports a controllable cycle start and
/// whose history read returns (or holds, then returns) a scripted result.
@MainActor
final class CursorHistoryAdapterSpy: ProviderAdapter {
    let provider = Provider.cursor
    let signInURL = URL(string: "https://cursor.com/dashboard")!
    var periodStart: Date
    var spentCents = 1234
    var historyResult: Result<CursorHistoryFetch?, Error> = .success(nil)
    var holdsHistory = false
    private(set) var historyRequests: [CursorHistoryRequest] = []
    private(set) var fetchCount = 0
    private(set) var vetoedCount = 0
    private var held: [CheckedContinuation<Void, Never>] = []

    init(periodStart: Date) {
        self.periodStart = periodStart
    }

    func verifySession(in webView: WKWebView) async throws {}

    func fetchUsage(accountID: UUID, in webView: WKWebView) async throws -> UsageSnapshot {
        fetchCount += 1
        let spend = CursorSpend(
            spentCents: spentCents, periodStart: periodStart,
            resetsAt: periodStart.addingTimeInterval(86_400), planLabel: "Pro"
        )
        return UsageSnapshot(
            accountID: accountID,
            fetchedAt: Date(timeIntervalSince1970: 1_000 + Double(fetchCount)),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: spend
        )
    }

    /// Like the real client: `mayDispatch` runs right before the script
    /// would reach the page (after any hold).
    func fetchCursorSpendHistory(
        _ request: CursorHistoryRequest,
        mayDispatch: @escaping @MainActor () throws -> Void,
        in webView: WKWebView
    ) async throws -> CursorHistoryFetch? {
        historyRequests.append(request)
        if holdsHistory {
            await withCheckedContinuation { continuation in
                held.append(continuation)
            }
        }
        do {
            try mayDispatch()
        } catch {
            vetoedCount += 1
            throw error
        }
        return try historyResult.get()
    }

    func releaseHistory() {
        holdsHistory = false
        let waiting = held
        held = []
        for continuation in waiting {
            continuation.resume()
        }
    }
}
