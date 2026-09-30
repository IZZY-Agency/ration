import Foundation
import Security

/// A Claude Code sign-in: the login (`claudeAiOauth`, sorted-key JSON) and the
/// account it belongs to.
struct ClaudeCodeSignIn: Equatable, Sendable {
    let account: ClaudeCodeAccount
    let login: Data
    let savedAt: Date

    var uuid: String { account.uuid }

    /// The value of a remembered-sign-in Keychain item — a fixed format, so
    /// sign-ins remembered by earlier builds carry over.
    func payload() -> Data {
        let object: [String: Any] = [
            ClaudeCodeKeychainEntry.loginKey: (try? JSONSerialization.jsonObject(with: login)) ?? [:],
            ClaudeCodeConfig.accountKey: (try? JSONSerialization.jsonObject(with: account.json)) ?? [:],
            "savedAt": savedAt.timeIntervalSince1970,
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    /// nil when the payload is not a sign-in for `uuid`.
    init?(payload: Data, uuid: String) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let login = object[ClaudeCodeKeychainEntry.loginKey],
              let section = object[ClaudeCodeConfig.accountKey] as? [String: Any],
              let account = ClaudeCodeConfig.account(from: section), account.uuid == uuid,
              let savedAt = (object["savedAt"] as? NSNumber)?.doubleValue
        else { return nil }
        self.init(account: account, login: ClaudeCodeKeychainEntry.canonical(login), savedAt: Date(timeIntervalSince1970: savedAt))
    }

    init(account: ClaudeCodeAccount, login: Data, savedAt: Date) {
        self.account = account
        self.login = login
        self.savedAt = savedAt
    }
}

/// Ration's own copies of remembered sign-ins (spec §4.2); a fake in tests.
protocol ClaudeCodeSignInStore: Sendable {
    func all() throws -> [ClaudeCodeSignIn]
    func save(_ signIn: ClaudeCodeSignIn) throws
    func delete(accountUUID: String) throws
}

/// One generic-password item per remembered account in the login Keychain,
/// never synchronized. The file-based keychain returns data for one item per
/// query, so the list is attributes first, then each item's data.
struct KeychainClaudeCodeSignInStore: ClaudeCodeSignInStore {
    static let service = "agency.izzy.ration.claude-code-session"

    enum Failure: Error, Equatable { case keychain(OSStatus) }

    private func query(_ uuid: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service]
        if let uuid { query[kSecAttrAccount as String] = uuid }
        return query
    }

    func all() throws -> [ClaudeCodeSignIn] {
        var list = query()
        list[kSecMatchLimit as String] = kSecMatchLimitAll
        list[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(list as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { throw Failure.keychain(status) }
        return rows.compactMap { row -> ClaudeCodeSignIn? in
            guard let uuid = row[kSecAttrAccount as String] as? String else { return nil }
            var one = query(uuid)
            one[kSecReturnData as String] = true
            one[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            guard SecItemCopyMatching(one as CFDictionary, &value) == errSecSuccess, let data = value as? Data else { return nil }
            return ClaudeCodeSignIn(payload: data, uuid: uuid)
        }
    }

    func save(_ signIn: ClaudeCodeSignIn) throws {
        let data = signIn.payload()
        let update = SecItemUpdate(query(signIn.uuid) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = query(signIn.uuid)
            add[kSecAttrLabel as String] = "Ration: Claude Code sign-in"
            add[kSecAttrSynchronizable as String] = false
            add[kSecValueData as String] = data
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure.keychain(status) }
        } else if update != errSecSuccess {
            throw Failure.keychain(update)
        }
    }

    func delete(accountUUID: String) throws {
        let status = SecItemDelete(query(accountUUID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }
}
