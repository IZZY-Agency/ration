import Foundation

/// The account Claude Code shows, from `~/.claude.json` › `oauthAccount`.
/// `json` is the whole section as read (sorted keys), written back as is.
struct ClaudeCodeAccount: Codable, Equatable, Sendable {
    let uuid: String
    let organizationUUID: String?
    let organizationName: String?
    let billingType: String?
    /// Changes when Claude Code signs in; compared, never interpreted.
    let profileFetchedAt: Double?
    let json: Data
}

/// Reading and rewriting `~/.claude.json` (spec §4.1). Only `oauthAccount` is
/// decoded or changed; every other key is written back as read.
enum ClaudeCodeConfig {
    static let accountKey = "oauthAccount"

    enum Failure: Error, Equatable { case notJSON }

    static func account(in bytes: Data) throws -> ClaudeCodeAccount? {
        guard let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.notJSON }
        return (object[accountKey] as? [String: Any]).flatMap(account(from:))
    }

    /// The account in one `oauthAccount` section; nil without an `accountUuid`.
    static func account(from section: [String: Any]) -> ClaudeCodeAccount? {
        guard let uuid = section["accountUuid"] as? String else { return nil }
        return ClaudeCodeAccount(
            uuid: uuid,
            organizationUUID: section["organizationUuid"] as? String,
            organizationName: section["organizationName"] as? String,
            billingType: section["billingType"] as? String,
            profileFetchedAt: (section["profileFetchedAt"] as? NSNumber)?.doubleValue,
            json: ClaudeCodeKeychainEntry.canonical(section)
        )
    }

    static func replacingAccount(in bytes: Data, with accountJSON: Data) throws -> Data {
        guard var object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let section = try? JSONSerialization.jsonObject(with: accountJSON) as? [String: Any]
        else { throw Failure.notJSON }
        object[accountKey] = section
        return try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .withoutEscapingSlashes])
    }
}

/// Access to `~/.claude.json`; a fake in tests, so none touches the real file.
protocol ClaudeCodeConfigAccess: Sendable {
    /// nil when the file does not exist.
    func readBytes() throws -> Data?
    func write(_ bytes: Data) throws
    func modificationDate() -> Date?
}

struct ClaudeCodeConfigFile: ClaudeCodeConfigAccess {
    let url: URL

    /// The user's real home: the sandbox's home is the container.
    static var userHome: URL {
        getpwuid(getuid()).map { URL(fileURLWithPath: String(cString: $0.pointee.pw_dir), isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    /// `~/.claude.json`, the one home file the app's signature lets it open.
    static var userConfigURL: URL { userHome.appending(path: ".claude.json") }

    func readBytes() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { return nil }
        return try Data(contentsOf: url)
    }

    /// In place: the sandbox grants this one path, not a temporary file beside
    /// it, so the write cannot be atomic — the recovery journal covers that.
    func write(_ bytes: Data) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
    }

    func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    }
}
