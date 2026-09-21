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
            candidate[snapshot.accountID] = snapshot
            try await saveSnapshots(candidate)
            snapshots = candidate
        }
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
