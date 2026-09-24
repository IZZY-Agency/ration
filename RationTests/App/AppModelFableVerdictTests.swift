import WebKit
import XCTest
@testable import Ration

/// `AppModel.fableVerdicts`: the in-memory Fable verdict cache hydrated
/// asynchronously from rollup history after each snapshot ingestion.
@MainActor
final class AppModelFableVerdictTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    func testHydrationAfterIngestionPopulatesVerdict() async throws {
        let fixture = try makeFixture(now: base.addingTimeInterval(31 * 3_600))
        defer { fixture.removeFiles() }
        let account = try await signIn(fixture)
        XCTAssertNil(fixture.model.fableVerdicts[account.id])

        seedHistory(fixture, account: account, fableTracksWeekly: true)
        fixture.adapter.next = snapshotFor(account.id, hour: 30, fableTracksWeekly: true)
        await fixture.model.refreshAll(reason: .manual)
        await fixture.model.flushFableVerdicts()

        XCTAssertEqual(fixture.model.fableVerdicts[account.id], .counts)
    }

    func testHydrationReportsDoesNotCountForIdleFable() async throws {
        let fixture = try makeFixture(now: base.addingTimeInterval(31 * 3_600))
        defer { fixture.removeFiles() }
        let account = try await signIn(fixture)

        seedHistory(fixture, account: account, fableTracksWeekly: false)
        fixture.adapter.next = snapshotFor(account.id, hour: 30, fableTracksWeekly: false)
        await fixture.model.refreshAll(reason: .manual)
        await fixture.model.flushFableVerdicts()

        XCTAssertEqual(fixture.model.fableVerdicts[account.id], .doesNotCount)
    }

    func testRemovedAccountsLateResultIsDiscarded() async throws {
        let gate = ScanGate()
        let fixture = try makeFixture(
            now: base.addingTimeInterval(31 * 3_600),
            afterRollupScan: { await gate.hook() }
        )
        defer { fixture.removeFiles() }
        let account = try await signIn(fixture)

        seedHistory(fixture, account: account, fableTracksWeekly: true)
        fixture.adapter.next = snapshotFor(account.id, hour: 30, fableTracksWeekly: true)
        gate.arm()
        await fixture.model.refreshAll(reason: .manual)
        await gate.waitUntilSuspended()

        try await fixture.model.removeAccount(id: account.id)
        gate.release()
        await fixture.model.flushFableVerdicts()

        XCTAssertNil(fixture.model.fableVerdicts[account.id])
    }

    func testPausedAccountsLateResultIsDiscarded() async throws {
        let gate = ScanGate()
        let fixture = try makeFixture(
            now: base.addingTimeInterval(31 * 3_600),
            afterRollupScan: { await gate.hook() }
        )
        defer { fixture.removeFiles() }
        let account = try await signIn(fixture)

        seedHistory(fixture, account: account, fableTracksWeekly: true)
        fixture.adapter.next = snapshotFor(account.id, hour: 30, fableTracksWeekly: true)
        gate.arm()
        await fixture.model.refreshAll(reason: .manual)
        await gate.waitUntilSuspended()

        try await fixture.model.setPaused(accountID: account.id, paused: true)
        gate.release()
        await fixture.model.flushFableVerdicts()

        XCTAssertNil(fixture.model.fableVerdicts[account.id])
    }

    func testRemovingAnAccountDropsItsVerdict() async throws {
        let fixture = try makeFixture(now: base.addingTimeInterval(31 * 3_600))
        defer { fixture.removeFiles() }
        let account = try await signIn(fixture)
        seedHistory(fixture, account: account, fableTracksWeekly: true)
        fixture.adapter.next = snapshotFor(account.id, hour: 30, fableTracksWeekly: true)
        await fixture.model.refreshAll(reason: .manual)
        await fixture.model.flushFableVerdicts()
        XCTAssertEqual(fixture.model.fableVerdicts[account.id], .counts)

        try await fixture.model.removeAccount(id: account.id)

        XCTAssertNil(fixture.model.fableVerdicts[account.id])
    }

    // MARK: Sign-in hydration

    func testNewSignInHydratesExactlyOnce() async throws {
        let reads = ReadCounter()
        let fixture = try makeFixture(
            now: base.addingTimeInterval(31 * 3_600),
            afterRollupScan: { reads.count += 1 }
        )
        defer { fixture.removeFiles() }
        fixture.adapter.fetchWithFable = true

        _ = try await signIn(fixture)
        await fixture.model.flushFableVerdicts()

        XCTAssertEqual(reads.count, 1)
    }

    func testReauthenticationHydratesExactlyOnce() async throws {
        let reads = ReadCounter()
        let fixture = try makeFixture(
            now: base.addingTimeInterval(31 * 3_600),
            afterRollupScan: { reads.count += 1 }
        )
        defer { fixture.removeFiles() }
        let account = try await signIn(fixture)
        await fixture.model.flushFableVerdicts()
        reads.count = 0

        fixture.adapter.fetchWithFable = true
        let sessionID = try fixture.model.beginReauthentication(accountID: account.id)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        await fixture.model.flushFableVerdicts()

        XCTAssertEqual(reads.count, 1)
    }

    // MARK: Helpers

    private func signIn(_ fixture: FableFixture) async throws -> AccountRecord {
        try await fixture.model.load(startBackgroundRefresh: false)
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: "Personal")
        return try XCTUnwrap(fixture.model.accounts.first)
    }

    /// Hourly snapshots over 30 hours: weekly burns 1% per hour; Fable burns
    /// the same (tracks) or not at all.
    private func snapshotFor(_ accountID: UUID, hour: Int, fableTracksWeekly: Bool) -> UsageSnapshot {
        let step = Double(hour) * 0.01
        let fableRemaining: Double = fableTracksWeekly ? 1 - step : 1
        return UsageSnapshot(
            accountID: accountID,
            fetchedAt: base.addingTimeInterval(Double(hour) * 3_600),
            fiveHour: nil,
            weekly: UsageWindow(kind: .weekly, remainingFraction: 1 - step, resetsAt: nil),
            modelWeekly: UsageWindow(kind: .modelWeekly, remainingFraction: fableRemaining, resetsAt: nil)
        )
    }

    private func seedHistory(_ fixture: FableFixture, account: AccountRecord, fableTracksWeekly: Bool) {
        for hour in 0..<30 {
            fixture.model.history.record(
                account: account,
                snapshot: snapshotFor(account.id, hour: hour, fableTracksWeekly: fableTracksWeekly)
            )
        }
    }

    private func makeFixture(
        now: Date,
        afterRollupScan: (@MainActor () async -> Void)? = nil
    ) throws -> FableFixture {
        let directory = try makeTempDirectory()
        let adapter = FableAdapterSpy(firstFetchedAt: base.addingTimeInterval(-3_600))
        let model = AppModel(
            accountStore: AccountStore(fileURL: directory.appending(path: "accounts.json")),
            snapshotStore: UsageSnapshotStore(fileURL: directory.appending(path: "snapshots.json")),
            pendingProfileDeletionStore: PendingProfileDeletionStore(
                fileURL: directory.appending(path: "pending-profile-deletions.json")
            ),
            historyStore: UsageHistoryStore(
                rootDirectory: directory.appending(path: "history", directoryHint: .isDirectory),
                timeZone: TimeZone(identifier: "UTC")!,
                now: { now },
                afterRollupScan: afterRollupScan
            ),
            appSettings: AppSettings(fileURL: directory.appending(path: "app-settings.json")),
            alertStateStore: AlertStateStore(fileURL: directory.appending(path: "alert-state.json")),
            profileManager: AlertsWebProfileManagerSpy(),
            adapterRegistry: ProviderAdapterRegistry(adapters: [adapter]),
            now: { now },
            systemPowerObserver: NoopSystemPowerObserver()
        )
        return FableFixture(directory: directory, model: model, adapter: adapter)
    }
}

@MainActor
private struct FableFixture {
    let directory: URL
    let model: AppModel
    let adapter: FableAdapterSpy

    nonisolated func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Returns `next` when set; otherwise an empty snapshot at `firstFetchedAt`
/// (the sign-in verification fetch, older than every seeded sample).
@MainActor
private final class FableAdapterSpy: ProviderAdapter {
    let provider = Provider.claude
    let signInURL = URL(string: "https://claude.ai/")!
    let firstFetchedAt: Date
    var next: UsageSnapshot?
    /// The default snapshot also carries weekly + Fable windows.
    var fetchWithFable = false

    init(firstFetchedAt: Date) {
        self.firstFetchedAt = firstFetchedAt
    }

    func verifySession(in webView: WKWebView) async throws {}

    func fetchUsage(accountID: UUID, in webView: WKWebView) async throws -> UsageSnapshot {
        if let next {
            return next
        }
        guard fetchWithFable else {
            return UsageSnapshot(accountID: accountID, fetchedAt: firstFetchedAt, fiveHour: nil, weekly: nil)
        }
        return UsageSnapshot(
            accountID: accountID,
            fetchedAt: firstFetchedAt,
            fiveHour: nil,
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.9, resetsAt: nil),
            modelWeekly: UsageWindow(kind: .modelWeekly, remainingFraction: 0.9, resetsAt: nil)
        )
    }
}

@MainActor
private final class ReadCounter {
    var count = 0
}

/// Suspends the FIRST `loadRollups` scan after `arm()` until `release()`.
@MainActor
private final class ScanGate {
    private var armed = false
    private var continuation: CheckedContinuation<Void, Never>?
    private var suspendedWaiters: [CheckedContinuation<Void, Never>] = []
    private var didSuspend = false

    func arm() { armed = true }

    func hook() async {
        guard armed else { return }
        armed = false
        didSuspend = true
        for waiter in suspendedWaiters { waiter.resume() }
        suspendedWaiters.removeAll()
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilSuspended() async {
        guard !didSuspend else { return }
        await withCheckedContinuation { suspendedWaiters.append($0) }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
