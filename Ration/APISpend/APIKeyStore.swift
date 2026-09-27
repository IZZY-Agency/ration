import Foundation
import Security

/// Admin-key storage in the Keychain. The key never leaves this type except
/// as the return value of `read`, which the caller puts straight into one
/// request header.
protocol APIKeyStore: Sendable {
    func add(_ key: String, for orgID: UUID) throws
    func read(for orgID: UUID) throws -> String
    func update(_ key: String, for orgID: UUID) throws
    /// Succeeds when the item is gone, including when it never existed.
    func delete(for orgID: UUID) throws
    func allOrgIDs() throws -> [UUID]
}

/// File-based login keychain, default ACL, no access group, no data-protection
/// keychain (Ration ships no provisioning profile). The ACL behaviour across
/// signed updates was verified by hand across a real signed update.
struct KeychainAPIKeyStore: APIKeyStore {
    static let service = "agency.izzy.ration.api-admin-key"

    private func base(_ orgID: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Self.service,
         kSecAttrAccount as String: orgID.uuidString]
    }

    func add(_ key: String, for orgID: UUID) throws {
        var query = base(orgID)
        query[kSecAttrLabel as String] = "Ration API admin key"
        query[kSecAttrSynchronizable as String] = false
        query[kSecValueData as String] = Data(key.utf8)
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw APISpendError.keychain(status: status) }
    }

    func read(for orgID: UUID) throws -> String {
        var query = base(orgID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if let error = Self.readError(for: status) { throw error }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw APISpendError.keychain(status: errSecDecode)
        }
        return key
    }

    /// Updates the DATA only, so the item's access control is left as created.
    func update(_ key: String, for orgID: UUID) throws {
        let status = SecItemUpdate(base(orgID) as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
        if let error = Self.readError(for: status) { throw error }
    }

    func delete(for orgID: UUID) throws {
        if let error = Self.deleteError(for: SecItemDelete(base(orgID) as CFDictionary)) { throw error }
    }

    func allOrgIDs() throws -> [UUID] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = items as? [[String: Any]] else {
            throw APISpendError.keychain(status: status)
        }
        return rows.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)) }
    }

    static func readError(for status: OSStatus) -> APISpendError? {
        switch status {
        case errSecSuccess: nil
        case errSecItemNotFound: .keyMissing
        default: .keychain(status: status)
        }
    }

    /// `errSecItemNotFound` counts as deleted (idempotent cleanup).
    static func deleteError(for status: OSStatus) -> APISpendError? {
        status == errSecSuccess || status == errSecItemNotFound ? nil : .keychain(status: status)
    }
}
