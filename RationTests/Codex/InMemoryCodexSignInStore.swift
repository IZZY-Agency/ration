import Foundation
@testable import Ration

/// Ration's remembered Codex logins without the real Keychain.
final class InMemoryCodexSignInStore: CodexSignInStore, @unchecked Sendable {
    struct Failed: Error {}
    private let lock = NSLock()
    private var stored: [String: CodexSignIn] = [:]
    private var savedList: [CodexSignIn] = []
    private var failSave = false
    private var failDelete = false

    init(_ signIns: [CodexSignIn] = []) {
        for signIn in signIns { stored[signIn.id] = signIn }
    }

    /// Login id → copy.
    var items: [String: CodexSignIn] {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    var saveFails: Bool {
        get { lock.withLock { failSave } }
        set { lock.withLock { failSave = newValue } }
    }

    var deleteFails: Bool {
        get { lock.withLock { failDelete } }
        set { lock.withLock { failDelete = newValue } }
    }

    /// Every successful save, in order.
    var saves: [CodexSignIn] { lock.withLock { savedList } }

    /// Items that are there but whose read fails (a Keychain error, not
    /// "not found"): `all()` throws while one of them is stored.
    var unreadableIDs: Set<String> {
        get { lock.withLock { unreadable } }
        set { lock.withLock { unreadable = newValue } }
    }
    private var unreadable: Set<String> = []

    func all() throws -> [CodexSignIn] {
        try lock.withLock {
            if stored.keys.contains(where: unreadable.contains) { throw Failed() }
            return stored.values.sorted { $0.id < $1.id }
        }
    }

    /// Every item, readable or not.
    func deleteAll() throws {
        try lock.withLock {
            if failDelete { throw Failed() }
            stored.removeAll()
        }
    }

    func save(_ signIn: CodexSignIn) throws {
        try lock.withLock {
            if failSave { throw Failed() }
            stored[signIn.id] = signIn
            savedList.append(signIn)
        }
    }

    func delete(id: String) throws {
        try lock.withLock {
            if failDelete { throw Failed() }
            stored.removeValue(forKey: id)
        }
    }
}
