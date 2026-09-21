import Foundation

@MainActor
final class PendingProfileDeletionStore {
    typealias SaveProfileIDs = @MainActor (Set<UUID>) async throws -> Void

    private(set) var profileIDs: Set<UUID> = []

    private let fileStore: JSONFileStore<Set<UUID>>
    private let saveProfileIDs: SaveProfileIDs
    private let mutations = SerializedMutationQueue()

    init(fileURL: URL, saveProfileIDs: SaveProfileIDs? = nil) {
        let fileStore = JSONFileStore<Set<UUID>>(
            fileURL: fileURL,
            defaultValue: []
        )
        self.fileStore = fileStore
        self.saveProfileIDs = saveProfileIDs ?? { profileIDs in
            try await fileStore.save(profileIDs)
        }
    }

    func load() async throws {
        try await mutations.run { [self] in
            profileIDs = try await fileStore.load()
        }
    }

    func enqueue(_ profileID: UUID) async throws {
        try await mutations.run { [self] in
            var candidate = profileIDs
            candidate.insert(profileID)
            try await saveProfileIDs(candidate)
            profileIDs = candidate
        }
    }

    func remove(_ profileID: UUID) async throws {
        try await mutations.run { [self] in
            var candidate = profileIDs
            candidate.remove(profileID)
            try await saveProfileIDs(candidate)
            profileIDs = candidate
        }
    }
}
