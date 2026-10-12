import Foundation
@testable import Ration

/// `~/.codex/auth.json` in memory. Reads can come back half-written, writes
/// can fail (optionally after touching the file, as an interrupted in-place
/// write would), and hooks let a test play Codex writing between Ration's steps.
final class FakeCodexLoginFile: CodexLoginAccess, @unchecked Sendable {
    struct ReadFailed: Error {}
    struct WriteFailed: Error {}

    private let lock = NSLock()
    private var stored: Data?
    private var storedWrites: [Data] = []
    private var reads = 0
    private var attempts = 0
    private var pendingUnreadable = 0
    private var replacement: Data?

    /// What `modificationDate()` reports.
    var modification: Date?
    /// Every write fails without touching the file.
    var writeFails = false
    /// Write attempts (1-based) that fail without touching the file.
    var failingWrites: Set<Int> = []
    /// Write attempts (1-based) that leave a third of their bytes and then
    /// fail: an in-place write interrupted after the truncate.
    var partialWrites: Set<Int> = []
    /// Write attempts (1-based) that store every byte and then throw: a sync
    /// that failed after the bytes landed (`CodexAuthFile.Failure.syncFailed`).
    var writeThenFail: Set<Int> = []
    /// The error a failing write throws (a precondition failure of the real
    /// writer, say).
    var writeError: any Error = WriteFailed()
    /// Runs after each successful write with its attempt number (1-based):
    /// Codex writing right after Ration.
    var afterWrite: ((Int, inout Data?) -> Void)?
    /// Write attempt (1-based) → how many reads after it throw: the file
    /// unreadable right after Ration's write.
    var unreadableReadsAfterWrite: [Int: Int] = [:]
    /// Runs after each served read with its number (1-based): Codex writing
    /// right after Ration looked.
    var afterRead: ((Int, inout Data?) -> Void)?

    init(bytes: Data? = nil) { stored = bytes }

    /// nil = no file.
    var bytes: Data? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    /// The bytes of every successful write, in order.
    var writes: [Data] {
        get { lock.withLock { storedWrites } }
        set { lock.withLock { storedWrites = newValue } }
    }
    var readCount: Int { lock.withLock { reads } }

    /// The next N reads throw, like a read of a file Codex is rewriting.
    var unreadableReads: Int {
        get { lock.withLock { pendingUnreadable } }
        set { lock.withLock { pendingUnreadable = newValue } }
    }

    /// Becomes the file right after the next read is served (Codex writing
    /// between two of Ration's reads).
    var nextReadReplacement: Data? {
        get { lock.withLock { replacement } }
        set { lock.withLock { replacement = newValue } }
    }

    func readBytes() throws -> Data? {
        try lock.withLock {
            reads += 1
            if pendingUnreadable > 0 {
                pendingUnreadable -= 1
                throw ReadFailed()
            }
            let served = stored
            if let replacement {
                stored = replacement
                self.replacement = nil
            }
            afterRead?(reads, &stored)
            return served
        }
    }

    /// Like the real writer, never creates a missing file.
    func write(_ bytes: Data) throws {
        try lock.withLock {
            attempts += 1
            if stored == nil { throw CodexAuthFile.Failure.missing }
            if writeFails || failingWrites.contains(attempts) { throw writeError }
            if partialWrites.contains(attempts) {
                stored = bytes.prefix(bytes.count / 3)
                throw writeError
            }
            if writeThenFail.contains(attempts) {
                stored = bytes
                throw writeError
            }
            stored = bytes
            storedWrites.append(bytes)
            afterWrite?(attempts, &stored)
            if let count = unreadableReadsAfterWrite[attempts] { pendingUnreadable = count }
        }
    }

    func modificationDate() -> Date? { lock.withLock { modification } }
}
