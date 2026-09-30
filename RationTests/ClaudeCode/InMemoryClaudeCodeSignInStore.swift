import Foundation
@testable import Ration

/// Ration's remembered sign-ins without the real Keychain.
final class InMemoryClaudeCodeSignInStore: ClaudeCodeSignInStore, @unchecked Sendable {
    enum Op: Hashable { case all, save, delete }
    private let lock = NSLock()
    private var items: [String: ClaudeCodeSignIn] = [:]
    var failNext: [Op: Error] = [:]
    private(set) var saves: [ClaudeCodeSignIn] = []

    init(_ signIns: [ClaudeCodeSignIn] = []) {
        for signIn in signIns { items[signIn.uuid] = signIn }
    }

    private func maybeFail(_ op: Op) throws {
        if let error = lock.withLock({ failNext.removeValue(forKey: op) }) { throw error }
    }

    func all() throws -> [ClaudeCodeSignIn] {
        try maybeFail(.all)
        return lock.withLock { items.values.sorted { $0.uuid < $1.uuid } }
    }

    func save(_ signIn: ClaudeCodeSignIn) throws {
        try maybeFail(.save)
        lock.withLock {
            items[signIn.uuid] = signIn
            saves.append(signIn)
        }
    }

    func delete(accountUUID: String) throws {
        try maybeFail(.delete)
        _ = lock.withLock { items.removeValue(forKey: accountUUID) }
    }

    func signIn(_ uuid: String) -> ClaudeCodeSignIn? { lock.withLock { items[uuid] } }
}
