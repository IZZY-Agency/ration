import Combine
import Foundation

/// Cursor's per-account past-cycle totals (`cursor-spend-history.json`, next
/// to `snapshots.json`).
///
/// Its own small file rather than a field on `UsageSnapshot` or a series in
/// `UsageHistoryStore`: a snapshot is replaced wholesale on every poll (the
/// history would need a carry-over merge on each write), and the rollup store
/// is hourly percentage buckets with its own directory layout. Kept apart, a
/// corrupt history file costs only the history — never the snapshots — and a
/// removed account is dropped the same way `alert-state.json` drops it.
///
/// Deletions are durable: an account's removal is first recorded in
/// `cursor-spend-history-deletions.json`, and every later write (and every
/// launch) scrubs recorded accounts until one save without them succeeds.
///
/// `fileURL == nil` keeps it in memory (tests that do not care about it).
@MainActor
final class CursorSpendHistoryStore: ObservableObject {
    typealias SaveHistories = @MainActor ([UUID: CursorSpendHistory]) async throws -> Void

    @Published private(set) var histories: [UUID: CursorSpendHistory] = [:]
    /// Accounts whose entry must go, not yet confirmed gone from the file.
    private(set) var pendingDeletions: Set<UUID> = []

    private let fileURL: URL?
    private let fileStore: JSONFileStore<[UUID: CursorSpendHistory]>?
    private let deletionStore: JSONFileStore<[UUID]>?
    private let saveHistories: SaveHistories
    private let mutations = SerializedMutationQueue()

    init(fileURL: URL?, saveHistories: SaveHistories? = nil) {
        self.fileURL = fileURL
        var fileStore: JSONFileStore<[UUID: CursorSpendHistory]>?
        var deletionStore: JSONFileStore<[UUID]>?
        if let fileURL {
            fileStore = JSONFileStore<[UUID: CursorSpendHistory]>(fileURL: fileURL, defaultValue: [:])
            let deletionsURL = fileURL.deletingLastPathComponent().appending(path: "cursor-spend-history-deletions.json")
            deletionStore = JSONFileStore<[UUID]>(fileURL: deletionsURL, defaultValue: [])
        }
        self.fileStore = fileStore
        self.deletionStore = deletionStore
        if let saveHistories {
            self.saveHistories = saveHistories
        } else if let fileStore {
            self.saveHistories = { histories in
                try await fileStore.save(histories)
            }
        } else {
            self.saveHistories = { _ in }
        }
    }

    /// A missing file is an empty history. A file that does not decode is
    /// deleted (its totals may belong to removed accounts, and nothing could
    /// ever rewrite it); the backfill runs again. Recorded deletions are then
    /// retried. Never a failed launch.
    func load() async {
        try? await mutations.run { [self] in
            guard let fileStore else { return }
            do {
                histories = try await fileStore.load()
            } catch is DecodingError {
                histories = [:]
                if let fileURL {
                    try? FileManager.default.removeItem(at: fileURL)
                }
            } catch {
                histories = [:]
            }
            if let deletionStore {
                let recorded: [UUID]? = try? await deletionStore.load()
                pendingDeletions = Set(recorded ?? [])
            }
            if !pendingDeletions.isEmpty {
                try? await save(histories)
            }
        }
    }

    func history(for accountID: UUID) -> CursorSpendHistory {
        histories[accountID] ?? CursorSpendHistory()
    }

    /// Applies `transform` to the account's CURRENT value inside the queue, so
    /// two updates never overwrite each other. `isLive` is re-checked there
    /// too: an update queued behind an account removal must not bring the
    /// account's entry back. Returns false when `isLive` refused it.
    @discardableResult
    func update(
        accountID: UUID,
        isLive: @escaping @MainActor () -> Bool = { true },
        _ transform: @escaping @MainActor (CursorSpendHistory) -> CursorSpendHistory
    ) async throws -> Bool {
        var applied = false
        try await mutations.run { [self] in
            guard isLive() else { return }
            applied = true
            let before = history(for: accountID)
            let after = transform(before)
            guard after != before else { return }
            var candidate = histories
            candidate[accountID] = after
            try await save(candidate)
        }
        return applied
    }

    /// Records the deletion durably first, then drops the entry. A failed
    /// save leaves it recorded: every later write and launch retries it.
    func remove(accountID: UUID) async throws {
        try await mutations.run { [self] in
            pendingDeletions.insert(accountID)
            try? await persistDeletions()
            try await save(histories)
        }
    }

    /// Retries recorded deletions (after a failed remove or startup prune).
    func retryPendingDeletions() async throws {
        try await mutations.run { [self] in
            guard !pendingDeletions.isEmpty else { return }
            try await save(histories)
        }
    }

    /// Every write goes through here: recorded deletions are scrubbed from
    /// what is written, and forgotten once a write without them lands.
    private func save(_ candidate: [UUID: CursorSpendHistory]) async throws {
        var scrubbed = candidate
        for accountID in pendingDeletions {
            scrubbed.removeValue(forKey: accountID)
        }
        try await saveHistories(scrubbed)
        histories = scrubbed
        if !pendingDeletions.isEmpty {
            pendingDeletions = []
            try? await persistDeletions()
        }
    }

    private func persistDeletions() async throws {
        guard let deletionStore else { return }
        try await deletionStore.save(pendingDeletions.sorted { $0.uuidString < $1.uuidString })
    }
}
