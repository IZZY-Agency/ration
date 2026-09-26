import Combine
import Foundation
import os

enum RefreshReason: Sendable {
    case launch
    case popoverOpened
    case timer
    case manual
}

@MainActor
final class UsageRefreshCoordinator: ObservableObject {
    typealias FetchUsage = @MainActor (AccountRecord) async throws -> UsageSnapshot
    typealias Now = @MainActor () -> Date
    typealias Sleep = @Sendable (Duration) async throws -> Void

    @Published private(set) var states: [UUID: AccountViewState] = [:]

    /// Called after a snapshot is successfully saved for an account. Used to run
    /// the auto-start policy. Set by the owner after construction.
    var onSnapshotSaved: @MainActor (AccountRecord, UsageSnapshot) async -> Void = { _, _ in }

    /// Asked at DISPATCH, right before a refresh would mark the account
    /// loading and fetch: true drops the refresh without writing any state.
    /// The owner wires it to "a sign-in window is open on this account's web
    /// view". Checked here rather than when the account list is built,
    /// because a refresh can sit queued behind others while a window opens.
    var isDispatchSuppressed: @MainActor (AccountRecord) -> Bool = { _ in false }

    private let snapshotStore: UsageSnapshotStore
    private let now: Now
    private let sleep: Sleep
    private let fetchUsage: FetchUsage
    /// Background-poll interval provider: base cadence + jitter,
    /// relaxed in Low Power Mode. Injected so the timing is deterministic in
    /// tests; the live app wires it to `PollSchedule` + `SystemPowerObserver`.
    private let pollInterval: @MainActor () -> Duration
    private struct InFlightRefresh {
        let token: UUID
        let task: Task<Void, Never>
    }

    private var inFlight: [UUID: InFlightRefresh] = [:]

    /// Refreshes that got past suppression and went on to fetch, per account.
    /// Lets a caller tell whether a fetch STARTED after some moment.
    private var dispatchCounts: [UUID: Int] = [:]

    func dispatchCount(for accountID: UUID) -> Int {
        dispatchCounts[accountID] ?? 0
    }

    /// Account IDs with a usage refresh currently in flight. Read by the
    /// WebView-release path so a profile mid-fetch is never released.
    var inFlightAccountIDs: Set<UUID> { Set(inFlight.keys) }
    private var retryDates: [UUID: Date] = [:]
    private var backgroundTask: Task<Void, Never>?

    init(
        snapshotStore: UsageSnapshotStore,
        now: @escaping Now = { .now },
        sleep: @escaping Sleep = { duration in
            try await Task.sleep(for: duration)
        },
        pollInterval: @escaping @MainActor () -> Duration = {
            .seconds(PollSchedule.baseSeconds)
        },
        fetchUsage: @escaping FetchUsage
    ) {
        self.snapshotStore = snapshotStore
        self.now = now
        self.sleep = sleep
        self.pollInterval = pollInterval
        self.fetchUsage = fetchUsage
    }

    func state(for accountID: UUID) -> AccountViewState {
        states[accountID]
            ?? (snapshotStore.snapshot(for: accountID) == nil ? .unavailable : .current)
    }

    func refresh(account: AccountRecord, reason: RefreshReason) async {
        if let existingTask = inFlight[account.id] {
            await existingTask.task.value
            return
        }

        // Before `shouldSkipRefresh`, which itself writes state (`.current`
        // for a recent snapshot, `.rateLimited`): a suppressed account's
        // state is left exactly as it was. Checked again at dispatch.
        if isDispatchSuppressed(account) {
            return
        }

        if shouldSkipRefresh(accountID: account.id, reason: reason) {
            return
        }

        let token = UUID()
        let task = Task { @MainActor in
            await performRefresh(account: account)
            // Drop the entry BEFORE the task completes, so whoever awaited it
            // (`settle`) sees it gone and can start a fresh refresh.
            if inFlight[account.id]?.token == token {
                inFlight.removeValue(forKey: account.id)
            }
        }
        inFlight[account.id] = InFlightRefresh(token: token, task: task)
        await task.value
        if inFlight[account.id]?.token == token {
            inFlight.removeValue(forKey: account.id)
        }
    }

    /// Waits until no refresh is in flight for the account, including one
    /// that started while the caller was waiting.
    func settle(accountID: UUID) async {
        var awaited: UUID?
        while let current = inFlight[accountID], current.token != awaited {
            awaited = current.token
            await current.task.value
        }
    }

    func refreshAll(accounts: [AccountRecord], reason: RefreshReason) async {
        let tasks = accounts.map { account in
            Task { @MainActor in
                await refresh(account: account, reason: reason)
            }
        }
        for task in tasks {
            await task.value
        }
    }

    func cancel(accountID: UUID) async {
        let task = inFlight.removeValue(forKey: accountID)?.task
        task?.cancel()
        retryDates.removeValue(forKey: accountID)
        states.removeValue(forKey: accountID)
        await task?.value
    }

    func startBackgroundRefresh(
        accounts: @escaping @MainActor () -> [AccountRecord]
    ) {
        stopBackgroundRefresh()
        backgroundTask = Task { @MainActor [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                do {
                    try await sleep(pollInterval())
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                // No offline pre-gate: a poll while offline just fails fast
                // (.offline → stale, cheap retry). A reachability hard-gate
                // risked suppressing polling forever on a false-negative path
                // advisory — worse than the marginal saved fetch.
                await refreshAll(accounts: accounts(), reason: .timer)
            }
        }
    }

    func stopBackgroundRefresh() {
        backgroundTask?.cancel()
        backgroundTask = nil
    }

    private func shouldSkipRefresh(
        accountID: UUID,
        reason: RefreshReason
    ) -> Bool {
        let currentDate = now()

        if let retryDate = retryDates[accountID], retryDate > currentDate {
            states[accountID] = .rateLimited(retryAt: retryDate)
            return true
        }
        retryDates.removeValue(forKey: accountID)

        if
            case .popoverOpened = reason,
            let snapshot = snapshotStore.snapshot(for: accountID),
            currentDate.timeIntervalSince(snapshot.fetchedAt) < 60
        {
            states[accountID] = .current
            return true
        }

        return false
    }

    private func performRefresh(account: AccountRecord) async {
        if isDispatchSuppressed(account) {
            Self.logger.info(
                "refresh skipped account=\(account.id.uuidString, privacy: .public) reason=dispatchSuppressed"
            )
            return
        }
        dispatchCounts[account.id, default: 0] += 1
        if snapshotStore.snapshot(for: account.id) == nil {
            states[account.id] = .loading
        }

        do {
            let snapshot = try await fetchUsage(account)
            try Task.checkCancellation()
            guard snapshot.accountID == account.id else {
                throw ProviderError.integrationChanged
            }
            try await snapshotStore.save(snapshot)
            // The save runs in the store's own queue and suspends this task;
            // a cancel landing meanwhile has already dropped this account's
            // state. The snapshot is on disk either way (the removal path
            // deletes it after `cancel` returns), but no state, retry date or
            // `onSnapshotSaved` (auto-start, history) may follow.
            try Task.checkCancellation()
            retryDates.removeValue(forKey: account.id)
            states[account.id] = .current
            await onSnapshotSaved(account, snapshot)
        } catch is CancellationError {
            return
        } catch let error as ProviderError {
            guard !Task.isCancelled else {
                return discardAfterCancel(error, accountID: account.id)
            }
            handle(error, accountID: account.id)
        } catch {
            guard !Task.isCancelled else {
                return discardAfterCancel(error, accountID: account.id)
            }
            // Keep the real failure visible in the log even though it maps to
            // `.transport` for the badge — a bridge timeout, an invalid JS
            // response, and a store failure need different fixes.
            handle(.transport, accountID: account.id, underlying: error)
        }
    }

    /// `cancel(accountID:)` already dropped this account's state and retry
    /// date, then waits for the task to exit. A hung fetch exits by THROWING
    /// (the bridge timeout, up to `WebUsageClient.evaluationTimeout` later),
    /// not with `CancellationError` — writing that failure back would leave a
    /// ghost entry for a removed account, a wrong badge on a just-reauthed
    /// one, or a retry date that silently skips the next refresh.
    private func discardAfterCancel(_ error: any Error, accountID: UUID) {
        Self.logger.info(
            "refresh failure discarded after cancel account=\(accountID.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)"
        )
    }

    /// The app's only always-on diagnostic surface: without this, a provider
    /// frontend change (2026-08: claude.ai moved its usage page and every
    /// fetch went stale for days) is only diagnosable by forensics on
    /// persisted history gaps. `log stream --predicate 'subsystem ==
    /// "agency.izzy.ration"'` now answers "why is this account
    /// stale" directly.
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "agency.izzy.ration",
        category: "refresh"
    )

    private func handle(
        _ error: ProviderError,
        accountID: UUID,
        underlying: (any Error)? = nil
    ) {
        let detail = underlying.map { " underlying=\(String(describing: $0))" } ?? ""
        Self.logger.error(
            "refresh failed account=\(accountID.uuidString, privacy: .public) error=\(String(describing: error), privacy: .public)\(detail, privacy: .public)"
        )
        switch error {
        case .authenticationRequired:
            states[accountID] = .reauthenticationRequired
        case let .rateLimited(retryAt):
            if let retryAt {
                retryDates[accountID] = retryAt
            }
            states[accountID] = .rateLimited(retryAt: retryAt)
        case .integrationChanged:
            states[accountID] = .integrationChanged
        case .server, .offline, .transport:
            states[accountID] = snapshotStore.snapshot(for: accountID) == nil
                ? .unavailable
                : .stale(lastError: error)
        }
    }
}
