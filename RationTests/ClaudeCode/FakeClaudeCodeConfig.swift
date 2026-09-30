import Foundation
@testable import Ration

/// `~/.claude.json` in memory. Writes can fail (optionally leaving a truncated
/// file behind, as an interrupted in-place write would) and hooks let a test
/// play Claude Code changing the file between Ration's steps.
final class FakeClaudeCodeConfig: ClaudeCodeConfigAccess, @unchecked Sendable {
    struct WriteFailed: Error {}
    private let lock = NSLock()
    private var stored: Data?
    private var reads = 0
    private(set) var writeCount = 0
    /// Write numbers (1-based) that fail.
    var failingWrites: Set<Int> = []
    /// A failing write leaves half-written bytes, like a truncated in-place write.
    var truncateOnFail = true
    /// Write numbers that store their bytes (and run `afterWrite`) and then throw.
    var writeThenFail: Set<Int> = []
    /// What `modificationDate()` reports.
    var date: Date?
    var afterRead: ((Int, inout Data?) -> Void)?
    var afterWrite: ((Int, inout Data?) -> Void)?

    init(bytes: Data?) { stored = bytes }

    var bytes: Data? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func readBytes() throws -> Data? {
        lock.withLock {
            reads += 1
            let served = stored
            afterRead?(reads, &stored)
            return served
        }
    }

    func write(_ bytes: Data) throws {
        try lock.withLock {
            writeCount += 1
            if failingWrites.contains(writeCount) {
                if truncateOnFail { stored = bytes.prefix(bytes.count / 3) }
                throw WriteFailed()
            }
            stored = bytes
            afterWrite?(writeCount, &stored)
            if writeThenFail.contains(writeCount) { throw WriteFailed() }
        }
    }

    func modificationDate() -> Date? { lock.withLock { date } }
}

final class InMemoryJournal: ClaudeCodeJournalStore, @unchecked Sendable {
    private let lock = NSLock()
    private var record: ClaudeCodeSwitchJournal?
    /// Runs after each write: a test plays Claude Code writing mid-switch.
    var onWrite: (() -> Void)?

    init(_ record: ClaudeCodeSwitchJournal? = nil) { self.record = record }

    func read() -> ClaudeCodeSwitchJournal? { lock.withLock { record } }
    func write(_ journal: ClaudeCodeSwitchJournal) throws {
        lock.withLock { record = journal }
        onWrite?()
    }
    func clear() throws { lock.withLock { record = nil } }
}
