import Foundation
import XCTest
@testable import Ration

final class UsageRefreshCoordinatorTests: XCTestCase {
    @MainActor
    func testSuccessfulRefreshPersistsSnapshotAndMarksCurrent() async throws {
        let fixture = try await makeFixture()
        let expected = snapshot(accountID: fixture.account.id, fetchedAt: fixture.now.date)
        let coordinator = UsageRefreshCoordinator(
            snapshotStore: fixture.store,
            now: { fixture.now.date },
            fetchUsage: { _ in expected }
        )

        await coordinator.refresh(account: fixture.account, reason: .manual)

        XCTAssertEqual(fixture.store.snapshot(for: fixture.account.id), expected)
        XCTAssertEqual(coordinator.state(for: fixture.account.id), .current)
    }

    @MainActor
    func testConcurrentRefreshesForSameAccountShareOneRequest() async throws {
        let fixture = try await makeFixture()
        let recorder = FetchRecorder()
        let coordinator = UsageRefreshCoordinator(
            snapshotStore: fixture.store,
            now: { fixture.now.date },
            fetchUsage: { account in
                await recorder.record()
                try await Task.sleep(for: .milliseconds(100))
                return self.snapshot(accountID: account.id, fetchedAt: fixture.now.date)
            }
        )

        async let first: Void = coordinator.refresh(account: fixture.account, reason: .manual)
        async let second: Void = coordinator.refresh(account: fixture.account, reason: .manual)
        _ = await (first, second)

        let requestCount = await recorder.count
        XCTAssertEqual(requestCount, 1)
    }

    @MainActor
    func testPopoverRefreshSkipsSnapshotNewerThanOneMinute() async throws {
        let fixture = try await makeFixture()
        let recorder = FetchRecorder()
        try await fixture.store.save(
            snapshot(
                accountID: fixture.account.id,
                fetchedAt: fixture.now.date.addingTimeInterval(-30)
            )
        )
        let coordinator = UsageRefreshCoordinator(
            snapshotStore: fixture.store,
            now: { fixture.now.date },
            fetchUsage: { account in
                await recorder.record()
                return self.snapshot(accountID: account.id, fetchedAt: fixture.now.date)
            }
        )

        await coordinator.refresh(account: fixture.account, reason: .popoverOpened)

        let requestCount = await recorder.count
        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(coordinator.state(for: fixture.account.id), .current)
    }

    @MainActor
    func testOfflineFailurePreservesRealSnapshotAsStale() async throws {
        let fixture = try await makeFixture()
        let existing = snapshot(accountID: fixture.account.id, fetchedAt: fixture.now.date)
        try await fixture.store.save(existing)
        let coordinator = UsageRefreshCoordinator(
            snapshotStore: fixture.store,
            now: { fixture.now.date },
            fetchUsage: { _ in throw ProviderError.offline }
        )

        await coordinator.refresh(account: fixture.account, reason: .manual)

        XCTAssertEqual(fixture.store.snapshot(for: fixture.account.id), existing)
        XCTAssertEqual(
            coordinator.state(for: fixture.account.id),
            .stale(lastError: .offline)
        )
    }

    @MainActor
    func testAuthenticationFailureRequestsReauthentication() async throws {
        let fixture = try await makeFixture()
        let coordinator = UsageRefreshCoordinator(
            snapshotStore: fixture.store,
            now: { fixture.now.date },
            fetchUsage: { _ in throw ProviderError.authenticationRequired }
        )

        await coordinator.refresh(account: fixture.account, reason: .manual)

        XCTAssertEqual(
            coordinator.state(for: fixture.account.id),
            .reauthenticationRequired
        )
    }

    @MainActor
    func testRateLimitBlocksRequestsUntilRetryDate() async throws {
        let fixture = try await makeFixture()
        let recorder = FetchRecorder()
        let retryAt = fixture.now.date.addingTimeInterval(120)
        let coordinator = UsageRefreshCoordinator(
            snapshotStore: fixture.store,
            now: { fixture.now.date },
            fetchUsage: { _ in
                await recorder.record()
                throw ProviderError.rateLimited(retryAt: retryAt)
            }
        )

        await coordinator.refresh(account: fixture.account, reason: .manual)
        await coordinator.refresh(account: fixture.account, reason: .manual)

        let requestCount = await recorder.count
        XCTAssertEqual(requestCount, 1)
        XCTAssertEqual(
            coordinator.state(for: fixture.account.id),
            .rateLimited(retryAt: retryAt)
        )
    }

    @MainActor
    func testBackgroundRefreshWaitsFiveMinutesBeforeFetching() async throws {
        let fixture = try await makeFixture()
        let recorder = FetchRecorder()
        let sleeper = OneShotSleeper()
        let coordinator = UsageRefreshCoordinator(
            snapshotStore: fixture.store,
            now: { fixture.now.date },
            sleep: { duration in try await sleeper.sleep(duration) },
            fetchUsage: { account in
                await recorder.record()
                return self.snapshot(accountID: account.id, fetchedAt: fixture.now.date)
            }
        )

        coordinator.startBackgroundRefresh(accounts: { [fixture.account] })
        await recorder.wait(for: 1)
        coordinator.stopBackgroundRefresh()

        let requestedDuration = await sleeper.firstRequestedDuration
        XCTAssertEqual(requestedDuration, .seconds(300))
    }

    @MainActor
    func testCancelledRefreshCannotRemoveReplacementTask() async throws {
        let fixture = try await makeFixture()
        let fetcher = ControlledFetcher()
        let coordinator = UsageRefreshCoordinator(
            snapshotStore: fixture.store,
            now: { fixture.now.date },
            fetchUsage: { account in
                await fetcher.fetch(accountID: account.id, date: fixture.now.date)
            }
        )

        let first = Task {
            await coordinator.refresh(account: fixture.account, reason: .manual)
        }
        await fetcher.waitForCalls(1)

        let cancellation = Task {
            await coordinator.cancel(accountID: fixture.account.id)
        }
        await Task.yield()
        let replacement = Task {
            await coordinator.refresh(account: fixture.account, reason: .manual)
        }
        await fetcher.waitForCalls(2)
        await fetcher.resolveCall(0)
        await cancellation.value
        await first.value

        let duplicate = Task {
            await coordinator.refresh(account: fixture.account, reason: .manual)
        }
        try await Task.sleep(for: .milliseconds(20))
        let callCount = await fetcher.callCount
        XCTAssertEqual(callCount, 2)

        await fetcher.resolveCall(1)
        await replacement.value
        await duplicate.value
    }

    /// `cancel` drops the account's state and returns only
    /// once the in-flight task exits. A hung fetch exits up to a bridge
    /// timeout later, by THROWING — and that late failure must not write a
    /// ghost `.unavailable` back for an account that was just removed.
    @MainActor
    func testTimedOutFetchAfterCancelLeavesNoGhostState() async throws {
        let fixture = try await makeFixture()
        let fetcher = GatedFirstFetch()
        let coordinator = UsageRefreshCoordinator(
            snapshotStore: fixture.store,
            now: { fixture.now.date },
            fetchUsage: { account in
                try await fetcher.fetch(accountID: account.id, date: fixture.now.date)
            }
        )

        let refresh = Task {
            await coordinator.refresh(account: fixture.account, reason: .manual)
        }
        await fetcher.waitForFirstCall()
        XCTAssertEqual(coordinator.states[fixture.account.id], .loading)

        let cancellation = Task {
            await coordinator.cancel(accountID: fixture.account.id)
        }
        await waitUntilCancelled(fixture.account.id, in: coordinator)
        await fetcher.failFirst(with: WebUsageClientError.timedOut)
        await cancellation.value
        await refresh.value

        XCTAssertNil(
            coordinator.states[fixture.account.id],
            "a fetch that times out after cancel must not re-insert state for a removed account"
        )
    }

    /// Reauth shape: the account keeps its snapshot, so a
    /// late failure would read as `.stale` — a wrong badge on an account whose
    /// sign-in just succeeded.
    @MainActor
    func testFailureAfterCancelDoesNotShowStaleBadgeOnReauthedAccount() async throws {
        let fixture = try await makeFixture()
        try await fixture.store.save(
            snapshot(accountID: fixture.account.id, fetchedAt: fixture.now.date)
        )
        let fetcher = GatedFirstFetch()
        let coordinator = UsageRefreshCoordinator(
            snapshotStore: fixture.store,
            now: { fixture.now.date },
            fetchUsage: { account in
                try await fetcher.fetch(accountID: account.id, date: fixture.now.date)
            }
        )

        let refresh = Task {
            await coordinator.refresh(account: fixture.account, reason: .manual)
        }
        await fetcher.waitForFirstCall()
        let cancellation = Task {
            await coordinator.cancel(accountID: fixture.account.id)
        }
        await waitUntilCancelled(fixture.account.id, in: coordinator)
        await fetcher.failFirst(with: ProviderError.offline)
        await cancellation.value
        await refresh.value

        XCTAssertNil(coordinator.states[fixture.account.id])
        XCTAssertEqual(coordinator.state(for: fixture.account.id), .current)
    }

    /// A rate limit reported after cancel must not come back
    /// as a retry date either — it would silently skip the next refresh.
    @MainActor
    func testRateLimitAfterCancelDoesNotBlockTheNextRefresh() async throws {
        let fixture = try await makeFixture()
        let fetcher = GatedFirstFetch()
        let coordinator = UsageRefreshCoordinator(
            snapshotStore: fixture.store,
            now: { fixture.now.date },
            fetchUsage: { account in
                try await fetcher.fetch(accountID: account.id, date: fixture.now.date)
            }
        )

        let refresh = Task {
            await coordinator.refresh(account: fixture.account, reason: .manual)
        }
        await fetcher.waitForFirstCall()
        let cancellation = Task {
            await coordinator.cancel(accountID: fixture.account.id)
        }
        await waitUntilCancelled(fixture.account.id, in: coordinator)
        let retryAt = fixture.now.date.addingTimeInterval(600)
        await fetcher.failFirst(with: ProviderError.rateLimited(retryAt: retryAt))
        await cancellation.value
        await refresh.value

        await coordinator.refresh(account: fixture.account, reason: .manual)

        let callCount = await fetcher.callCount
        XCTAssertEqual(callCount, 2, "the refresh after cancel must fetch, not wait out a dead rate limit")
        XCTAssertEqual(coordinator.state(for: fixture.account.id), .current)
    }

    /// The SUCCESS path has the same hole. The
    /// save runs in the store's own serialized queue; if cancel lands while it
    /// is suspended, the refresh must not write `.current` back nor run
    /// `onSnapshotSaved` (auto-start, history) for a removed account.
    @MainActor
    func testCancelDuringSnapshotSaveLeavesNoStateAndSkipsTheCallback() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let saveGate = SaveGate()
        let store = UsageSnapshotStore(
            fileURL: directory.appending(path: "snapshots.json"),
            saveSnapshots: { _ in await saveGate.pass() }
        )
        try await store.load()
        let fixture = try await makeFixture()
        let account = fixture.account
        final class CallbackCounter { var count = 0 }
        let callbacks = CallbackCounter()
        let coordinator = UsageRefreshCoordinator(
            snapshotStore: store,
            now: { fixture.now.date },
            fetchUsage: { account in
                self.snapshot(accountID: account.id, fetchedAt: fixture.now.date)
            }
        )
        coordinator.onSnapshotSaved = { _, _ in callbacks.count += 1 }

        saveGate.arm()
        let refresh = Task {
            await coordinator.refresh(account: account, reason: .manual)
        }
        await saveGate.waitUntilHeld()
        let cancellation = Task {
            await coordinator.cancel(accountID: account.id)
        }
        await waitUntilCancelled(account.id, in: coordinator)
        saveGate.release()
        await cancellation.value
        await refresh.value

        XCTAssertNil(coordinator.states[account.id], "a save that completes after cancel must not write state back")
        XCTAssertEqual(callbacks.count, 0, "onSnapshotSaved must not run for a cancelled refresh")
    }

    /// `cancel` drops the in-flight marker synchronously, before it awaits the
    /// task — waiting on that (not on a yield) makes the ordering explicit.
    @MainActor
    private func waitUntilCancelled(
        _ accountID: UUID,
        in coordinator: UsageRefreshCoordinator
    ) async {
        while coordinator.inFlightAccountIDs.contains(accountID) {
            await Task.yield()
        }
    }

    @MainActor
    func testBackgroundRefreshUsesInjectedPollInterval() async throws {
        let fixture = try await makeFixture()
        let recorder = FetchRecorder()
        let sleeper = OneShotSleeper()
        let coordinator = UsageRefreshCoordinator(
            snapshotStore: fixture.store,
            now: { fixture.now.date },
            sleep: { duration in try await sleeper.sleep(duration) },
            pollInterval: { .seconds(PollSchedule.lowPowerSeconds) },
            fetchUsage: { account in
                await recorder.record()
                return self.snapshot(accountID: account.id, fetchedAt: fixture.now.date)
            }
        )

        coordinator.startBackgroundRefresh(accounts: { [fixture.account] })
        await recorder.wait(for: 1)
        coordinator.stopBackgroundRefresh()

        // The loop sleeps for the provider-supplied interval (e.g. relaxed in
        // Low Power Mode), not a hardcoded 300 s.
        let requested = await sleeper.firstRequestedDuration
        XCTAssertEqual(requested, .seconds(PollSchedule.lowPowerSeconds))
    }

    @MainActor
    private func makeFixture() async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = UsageSnapshotStore(
            fileURL: directory.appending(path: "snapshots.json")
        )
        try await store.load()
        return Fixture(
            account: AccountRecord(
                id: UUID(),
                provider: .claude,
                label: "Account",
                webProfileID: UUID(),
                displayOrder: 0,
                createdAt: Date(timeIntervalSince1970: 1_000)
            ),
            store: store,
            now: NowBox(date: Date(timeIntervalSince1970: 10_000))
        )
    }

    private func snapshot(accountID: UUID, fetchedAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            fetchedAt: fetchedAt,
            fiveHour: nil,
            weekly: nil
        )
    }
}

@MainActor
private struct Fixture {
    let account: AccountRecord
    let store: UsageSnapshotStore
    let now: NowBox
}

@MainActor
private final class NowBox {
    var date: Date

    init(date: Date) {
        self.date = date
    }
}

private actor FetchRecorder {
    private(set) var count = 0
    private var waiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func record() {
        count += 1
        let ready = waiters.filter { count >= $0.count }
        waiters.removeAll { count >= $0.count }
        ready.forEach { $0.continuation.resume() }
    }

    func wait(for expectedCount: Int) async {
        guard count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            waiters.append((expectedCount, continuation))
        }
    }
}

private actor OneShotSleeper {
    private(set) var firstRequestedDuration: Duration?
    private var requestCount = 0

    func sleep(_ duration: Duration) throws {
        requestCount += 1
        if firstRequestedDuration == nil {
            firstRequestedDuration = duration
        }
        if requestCount > 1 {
            throw CancellationError()
        }
    }
}

private actor ControlledFetcher {
    private struct Request {
        let accountID: UUID
        let date: Date
        let continuation: CheckedContinuation<UsageSnapshot, Never>
    }

    private var requests: [Request] = []
    private var callWaiters: [(
        count: Int,
        continuation: CheckedContinuation<Void, Never>
    )] = []

    var callCount: Int { requests.count }

    func fetch(accountID: UUID, date: Date) async -> UsageSnapshot {
        await withCheckedContinuation { continuation in
            requests.append(
                Request(
                    accountID: accountID,
                    date: date,
                    continuation: continuation
                )
            )
            let ready = callWaiters.filter { requests.count >= $0.count }
            callWaiters.removeAll { requests.count >= $0.count }
            ready.forEach { $0.continuation.resume() }
        }
    }

    func waitForCalls(_ expectedCount: Int) async {
        guard requests.count < expectedCount else { return }
        await withCheckedContinuation { continuation in
            callWaiters.append((expectedCount, continuation))
        }
    }

    func resolveCall(_ index: Int) {
        let request = requests[index]
        request.continuation.resume(
            returning: UsageSnapshot(
                accountID: request.accountID,
                fetchedAt: request.date,
                fiveHour: nil,
                weekly: nil
            )
        )
    }
}

/// The first fetch parks until the test fails it; every later fetch succeeds
/// at once.
private actor GatedFirstFetch {
    private(set) var callCount = 0
    private var first: CheckedContinuation<UsageSnapshot, any Error>?
    private var started = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    func fetch(accountID: UUID, date: Date) async throws -> UsageSnapshot {
        callCount += 1
        guard callCount == 1 else {
            return UsageSnapshot(accountID: accountID, fetchedAt: date, fiveHour: nil, weekly: nil)
        }
        return try await withCheckedThrowingContinuation { continuation in
            first = continuation
            started = true
            startWaiters.forEach { $0.resume() }
            startWaiters.removeAll()
        }
    }

    func waitForFirstCall() async {
        guard !started else { return }
        await withCheckedContinuation { startWaiters.append($0) }
    }

    func failFirst(with error: any Error) {
        first?.resume(throwing: error)
        first = nil
    }
}

/// Holds the next armed snapshot save until released.
@MainActor
private final class SaveGate {
    private var armed = false
    private var held: CheckedContinuation<Void, Never>?
    private var heldWaiters: [CheckedContinuation<Void, Never>] = []

    func arm() { armed = true }

    func pass() async {
        guard armed else { return }
        armed = false
        await withCheckedContinuation { continuation in
            held = continuation
            heldWaiters.forEach { $0.resume() }
            heldWaiters.removeAll()
        }
    }

    func waitUntilHeld() async {
        guard held == nil else { return }
        await withCheckedContinuation { heldWaiters.append($0) }
    }

    func release() {
        held?.resume()
        held = nil
    }
}
