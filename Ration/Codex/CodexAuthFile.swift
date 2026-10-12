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

    /// Why a write was refused; the file is left untouched.
    enum Failure: Error, Equatable {
        /// A symlink, a directory, anything but a plain file.
        case notARegularFile
        case notOwned
        /// Not exactly 0600: Codex keeps its login owner-only, and a file that
        /// is not is not one Ration should write a login into.
        case permissive(mode: Int)
        /// Nothing to switch: a switch never creates the file.
        case missing
        /// Every byte was written but `fsync` failed: the file may hold the
        /// new login without it being on disk. Unlike the others, thrown
        /// after the file changed.
        case syncFailed
    }

    func readBytes() throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil
        }
    }

    /// Opens `O_WRONLY | O_NOFOLLOW` (never `O_CREAT`), proves through the
    /// descriptor that it is a regular file owned by this user with mode
    /// 0600, then truncates, writes every byte and syncs (spec §4.1). Any
    /// failed check throws `Failure` before a byte changes;
    /// a failed sync throws `.syncFailed` after they did.
    func write(_ bytes: Data) throws {
        let descriptor = open(url.path(percentEncoded: false), O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: throw Failure.missing
            case ELOOP, EISDIR, ENOTDIR: throw Failure.notARegularFile
            default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard status.st_mode & S_IFMT == S_IFREG else { throw Failure.notARegularFile }
        guard status.st_uid == getuid() else { throw Failure.notOwned }
        let mode = Int(status.st_mode & 0o7777)
        guard mode == 0o600 else { throw Failure.permissive(mode: mode) }

        guard ftruncate(descriptor, 0) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                offset += written
            }
        }
        try Self.sync(descriptor)
    }

    /// `fsync`, once more when a signal interrupted it; then `.syncFailed`.
    static func sync(_ descriptor: Int32, using sync: (Int32) -> Int32 = { fsync($0) }) throws {
        if sync(descriptor) == 0 { return }
        if errno == EINTR, sync(descriptor) == 0 { return }
        throw Failure.syncFailed
    }

    func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.modificationDate] as? Date
    }
}
