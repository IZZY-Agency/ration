import Combine
import Foundation

@MainActor
final class AlertStateStore: ObservableObject {
    typealias SaveStates = @MainActor ([UUID: AccountAlertState]) async throws -> Void

    @Published private(set) var states: [UUID: AccountAlertState] = [:]

    private let fileStore: JSONFileStore<[UUID: AccountAlertState]>
    private let saveStates: SaveStates
    private let mutations = SerializedMutationQueue()

    init(fileURL: URL, saveStates: SaveStates? = nil) {
        let fileStore = JSONFileStore<[UUID: AccountAlertState]>(
            fileURL: fileURL,
            defaultValue: [:]
        )
        self.fileStore = fileStore
        self.saveStates = saveStates ?? { states in
            try await fileStore.save(states)
        }
    }

    func load() async throws {
        try await mutations.run { [self] in
            do {
                states = try await fileStore.load()
            } catch is DecodingError {
                // Corrupt JSON defaults to an empty map without throwing
                states = [:]
            }
        }
    }

    func state(for accountID: UUID) -> AccountAlertState {
        states[accountID] ?? AccountAlertState()
    }

    func save(_ state: AccountAlertState, for accountID: UUID) async throws {
        try await mutations.run { [self] in
            var candidate = states
            candidate[accountID] = state
            try await saveStates(candidate)
            states = candidate
        }
    }

    func remove(accountID: UUID) async throws {
        try await mutations.run { [self] in
            var candidate = states
            candidate.removeValue(forKey: accountID)
            try await saveStates(candidate)
            states = candidate
        }
    }
}
