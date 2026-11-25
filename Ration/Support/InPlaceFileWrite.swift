import Foundation

/// The in-place write of the two home files the sandbox lets Ration open
/// (`~/.claude.json`, `~/.codex/auth.json`). The sandbox grants each path
/// itself, not a temporary file beside it, so a write can never be atomic;
/// what it can be is checked: the file is opened without following a
/// symlink and without creating it, and proven through the descriptor to be
/// the user's own regular file before a byte changes.
enum InPlaceFileWrite {
    /// Why a write was refused; the file is left untouched (except `.syncFailed`).
    enum Failure: Error, Equatable {
        /// A symlink, a directory, anything but a plain file.
        case notARegularFile
        case notOwned
        /// Not exactly the mode the caller requires.
        case permissive(mode: Int)
        /// The file is never created.
        case missing
        /// Every byte was written but `fsync` failed: the file may hold the
        /// new bytes without them being on disk. Unlike the others, thrown
        /// after the file changed.
        case syncFailed
    }

    /// Opens `O_WRONLY | O_NOFOLLOW` (never `O_CREAT`), proves through the
    /// descriptor that it is a regular file owned by this user (with exactly
    /// `requiredMode`, when given), then truncates, writes every byte and
    /// syncs. Any failed check throws `Failure` before a byte changes; a
    /// failed sync throws `.syncFailed` after they did.
    /// `readable`: the file must be one the user can read too, so a file
    /// that cannot be read back is refused rather than overwritten blind.
    /// `owner` and `syncing` are parameters for the tests only.
    static func write(_ bytes: Data, to url: URL, requiredMode: Int? = nil, readable: Bool = false,
                      owner: uid_t = getuid(), syncing: (Int32) -> Int32 = { fsync($0) }) throws {
        let descriptor = try openChecked(url, requiredMode: requiredMode, readable: readable, owner: owner)
        defer { close(descriptor) }

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
        try sync(descriptor, using: syncing)
    }

    /// The checks of `write` alone: throws what a write would be refused
    /// with, and changes nothing. For a caller that must know before it
    /// changes something else; the write still checks for itself, since the
    /// path can change in between.
    static func check(_ url: URL, requiredMode: Int? = nil, readable: Bool = false, owner: uid_t = getuid()) throws {
        close(try openChecked(url, requiredMode: requiredMode, readable: readable, owner: owner))
    }

    private static func openChecked(_ url: URL, requiredMode: Int?, readable: Bool, owner: uid_t) throws -> Int32 {
        let descriptor = open(url.path(percentEncoded: false), (readable ? O_RDWR : O_WRONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            switch errno {
            case ENOENT: throw Failure.missing
            case ELOOP, EISDIR, ENOTDIR: throw Failure.notARegularFile
            default: throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
        do {
            var status = stat()
            guard fstat(descriptor, &status) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard status.st_mode & S_IFMT == S_IFREG else { throw Failure.notARegularFile }
            guard status.st_uid == owner else { throw Failure.notOwned }
            let mode = Int(status.st_mode & 0o7777)
            if let requiredMode, mode != requiredMode { throw Failure.permissive(mode: mode) }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    /// `fsync`, once more when a signal interrupted it; then `.syncFailed`.
    static func sync(_ descriptor: Int32, using sync: (Int32) -> Int32 = { fsync($0) }) throws {
        if sync(descriptor) == 0 { return }
        if errno == EINTR, sync(descriptor) == 0 { return }
        throw Failure.syncFailed
    }
}
