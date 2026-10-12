import Foundation
import Security

/// A remembered Codex login: the file's exact bytes and when Ration saved
/// them. `savedAt` decides whether the copy is still usable (7 days, spec
/// §4.2) and names the rollback source in the journal (spec §4.1).
struct CodexSignIn: Equatable, Sendable {
    let login: CodexLogin
    /// Whole seconds: the journal file keeps ISO 8601 seconds, and a copy is
    /// named by this exact time.
    let savedAt: Date

    var id: String { login.id }

    init(login: CodexLogin, savedAt: Date) {
        self.login = login
        self.savedAt = Date(timeIntervalSince1970: savedAt.timeIntervalSince1970.rounded(.down))
    }

    /// The Keychain item's value, `{"auth": <the file's bytes, base64>, "savedAt": <seconds>}`
    /// (spec §4.2): the bytes as Codex wrote them, so a switch writes back
    /// exactly that file. No re-serialisation.
    func payload() -> Data {
        let object: [String: Any] = ["auth": login.bytes.base64EncodedString(), "savedAt": Int64(savedAt.timeIntervalSince1970)]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    /// nil when the payload is not a whole login whose id — both the account
    /// and the user — equals `id`, or is undecodable.
    init?(payload: Data, id: String) {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let auth = (object["auth"] as? String).flatMap({ Data(base64Encoded: $0) }),
              let seconds = (object["savedAt"] as? NSNumber)?.doubleValue,
              let login = try? CodexLogin(fileBytes: auth), login.id == id
        else { return nil }
        self.init(login: login, savedAt: Date(timeIntervalSince1970: seconds))
    }
}

/// Ration's own copies of remembered Codex logins (spec §4.2); a fake in tests.
protocol CodexSignInStore: Sendable {
    /// Every copy that decodes; one that cannot be read at all throws.
    func all() throws -> [CodexSignIn]
    func save(_ signIn: CodexSignIn) throws
    func delete(id: String) throws
    /// Every copy Ration keeps — decodable, readable or not (Forget all).
    func deleteAll() throws
}

/// One generic-password item per remembered login in the login Keychain,
/// keyed by the login id, never synchronized. The file-based keychain returns
/// data for one item per query, so the list is attributes first, then each
/// item's data. Production only: no test touches the real Keychain.
struct KeychainCodexSignInStore: CodexSignInStore {
    static let service = "agency.izzy.ration.codex-session"
    static let label = "Ration: Codex sign-in"

    enum Failure: Error, Equatable { case keychain(OSStatus) }

    private func query(_ id: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service]
        if let id { query[kSecAttrAccount as String] = id }
        return query
    }

    /// An item whose payload does not decode to its login is skipped; one
    /// whose read fails (anything but "not found": gone since the listing)
    /// throws, so a copy is never silently left out.
    func all() throws -> [CodexSignIn] {
        var list = query()
        list[kSecMatchLimit as String] = kSecMatchLimitAll
        list[kSecReturnAttributes as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(list as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = result as? [[String: Any]] else { throw Failure.keychain(status) }
        return try rows.compactMap { row -> CodexSignIn? in
            guard let id = row[kSecAttrAccount as String] as? String else { return nil }
            var one = query(id)
            one[kSecReturnData as String] = true
            one[kSecMatchLimit as String] = kSecMatchLimitOne
            var value: CFTypeRef?
            let read = SecItemCopyMatching(one as CFDictionary, &value)
            if read == errSecItemNotFound { return nil }
            guard read == errSecSuccess else { throw Failure.keychain(read) }
            guard let data = value as? Data else { return nil }
            return CodexSignIn(payload: data, id: id)
        }
        .sorted { $0.id < $1.id }
    }

    func save(_ signIn: CodexSignIn) throws {
        let data = signIn.payload()
        let update = SecItemUpdate(query(signIn.id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecItemNotFound {
            var add = query(signIn.id)
            add[kSecAttrLabel as String] = Self.label
            add[kSecAttrSynchronizable as String] = false
            add[kSecValueData as String] = data
            let status = SecItemAdd(add as CFDictionary, nil)
            guard status == errSecSuccess else { throw Failure.keychain(status) }
        } else if update != errSecSuccess {
            throw Failure.keychain(update)
        }
    }

    func delete(id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure.keychain(status) }
    }

    /// Every item of the service, by the service alone — never by reading
    /// them first, so one that cannot be read or decoded goes too. Repeated
    /// until none is left: a keychain that deletes one match per call is
    /// emptied as well (bounded, in case an item resists).
    func deleteAll() throws {
        for _ in 0..<1_000 {
            let status = SecItemDelete(query() as CFDictionary)
            if status == errSecItemNotFound { return }
            guard status == errSecSuccess else { throw Failure.keychain(status) }
        }
        throw Failure.keychain(errSecDuplicateItem)
    }
}
