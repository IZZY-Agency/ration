import Foundation
@testable import Ration

final class InMemoryAPIKeyStore: APIKeyStore, @unchecked Sendable {
    enum Op: Hashable { case add, read, update, delete, list }
    private let lock = NSLock()
    private var keys: [UUID: String] = [:]
    var failNext: [Op: APISpendError] = [:]
    private(set) var deleted: [UUID] = []

    private func maybeFail(_ op: Op) throws {
        if let error = lock.withLock({ failNext.removeValue(forKey: op) }) { throw error }
    }

    func add(_ key: String, for orgID: UUID) throws { try maybeFail(.add); lock.withLock { keys[orgID] = key } }
    func read(for orgID: UUID) throws -> String {
        try maybeFail(.read)
        guard let key = lock.withLock({ keys[orgID] }) else { throw APISpendError.keyMissing }
        return key
    }
    func update(_ key: String, for orgID: UUID) throws {
        try maybeFail(.update)
        try lock.withLock {
            guard keys[orgID] != nil else { throw APISpendError.keyMissing }
            keys[orgID] = key
        }
    }
    func delete(for orgID: UUID) throws { try maybeFail(.delete); lock.withLock { keys[orgID] = nil; deleted.append(orgID) } }
    func allOrgIDs() throws -> [UUID] { try maybeFail(.list); return lock.withLock { Array(keys.keys) } }
    func seed(_ key: String, for orgID: UUID) { lock.withLock { keys[orgID] = key } }
}
