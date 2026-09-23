import Combine
import Foundation

@MainActor
final class UsageSnapshotStore: ObservableObject {
    typealias SaveSnapshots = @MainActor (
        [UUID: UsageSnapshot]
    ) async throws -> Void

    @Published private(set) var snapshots: [UUID: UsageSnapshot] = [:]

    var count: Int { snapshots.count }

    private let fileStore: JSONFileStore<[UUID: UsageSnapshot]>
    private let saveSnapshots: SaveSnapshots
    private let mutations = SerializedMutationQueue()

    init(fileURL: URL, saveSnapshots: SaveSnapshots? = nil) {
        let fileStore = JSONFileStore<[UUID: UsageSnapshot]>(
            fileURL: fileURL,
            defaultValue: [:]
        )
        self.fileStore = fileStore
        self.saveSnapshots = saveSnapshots ?? { snapshots in
            try await fileStore.save(snapshots)
        }
    }

    func load() async throws {
        try await mutations.run { [self] in
            snapshots = try await fileStore.load()
        }
    }

    func snapshot(for accountID: UUID) -> UsageSnapshot? {
        snapshots[accountID]
    }

    func save(_ snapshot: UsageSnapshot) async throws {
        try await mutations.run { [self] in
            var candidate = snapshots
            candidate[snapshot.accountID] = Self.merged(
                incoming: snapshot,
                previous: snapshots[snapshot.accountID]
            )
            try await saveSnapshots(candidate)
            snapshots = candidate
        }
    }

    /// THE one place a snapshot that did not read resets inherits the last
    /// list. Every writer (refresh, warm-up refetch, re-auth commit) goes
    /// through `save`, so none of them can erase resets by accident.
    ///
    /// The carried list keeps its OWN `fetchedAt`, which is how alerts tell
    /// it apart from a fresh read. It is dropped when both sides know their
    /// claude.ai organization and they differ — a workspace switch must not
    /// show one org's resets under another. After a relaunch the previous org
    /// is unknown (never persisted); the list is then display-only until the
    /// next successful read, and alerts only act on fresh reads.
    static func merged(incoming: UsageSnapshot, previous: UsageSnapshot?) -> UsageSnapshot {
        guard incoming.resetCredits == nil, let previous, let carried = previous.resetCredits else {
            return incoming
        }
        if
            let before = previous.organizationID,
            let after = incoming.organizationID,
            before != after
        {
            return incoming
        }
        return incoming.replacingResetCredits(carried)
    }

    func remove(accountID: UUID) async throws {
        try await mutations.run { [self] in
            var candidate = snapshots
            candidate.removeValue(forKey: accountID)
            try await saveSnapshots(candidate)
            snapshots = candidate
        }
    }
}
