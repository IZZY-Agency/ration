import Foundation

/// Access to `~/.codex/auth.json`; a fake in tests, so none touches the real file.
protocol CodexLoginAccess: Sendable {
    /// nil when the file does not exist.
    func readBytes() throws -> Data?
    /// The whole file, in place.
    func write(_ bytes: Data) throws
    func modificationDate() -> Date?
}

/// The real file. The sandbox grants this one path (a home-relative
/// read-write exception), not a temporary file beside it, so a write is in
/// place, never atomic: the switcher's journal and read-back cover that
/// (spec §4.1).
struct CodexAuthFile: CodexLoginAccess {
    let url: URL

    /// The user's real `~/.codex/auth.json`: the home from the user database,
    /// not the sandbox container. Ration controls only this default file
    /// (no `CODEX_HOME`, no keyring store; spec §1 non-goals).
    static var userAuthURL: URL { ClaudeCodeConfigFile.userHome.appending(path: ".codex/auth.json") }

    /// Why a write was refused. `.permissive`: not exactly 0600 — Codex keeps
    /// its login owner-only, and a file that is not is not one Ration should
    /// write a login into. `.missing`: a switch never creates the file.
    typealias Failure = InPlaceFileWrite.Failure

    func readBytes() throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil
        }
    }

    /// In place, through a descriptor proven to be the user's own regular
    /// file with mode 0600 (spec §4.1); see `InPlaceFileWrite`.
    func write(_ bytes: Data) throws {
        try InPlaceFileWrite.write(bytes, to: url, requiredMode: 0o600)
    }

    static func sync(_ descriptor: Int32, using sync: (Int32) -> Int32 = { fsync($0) }) throws {
        try InPlaceFileWrite.sync(descriptor, using: sync)
    }

    func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    }
}
