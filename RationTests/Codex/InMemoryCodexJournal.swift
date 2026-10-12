import Foundation
@testable import Ration

/// The switch journal without a file.
final class InMemoryCodexJournal: CodexJournalStore, @unchecked Sendable {
    struct Failed: Error {}
    private let lock = NSLock()
    private var record: CodexSwitchJournal?
    private var writeCount = 0
    private var failRead = false
    private var failClear = false
    /// Runs after each successful write: a test plays Codex writing mid-switch.
    var onWrite: (() -> Void)?
    var writeFails = false

    init(_ record: CodexSwitchJournal? = nil) { self.record = record }

    var writes: Int { lock.withLock { writeCount } }

    /// Every read throws: a journal file that exists but cannot be read or decoded.
    var readFails: Bool {
        get { lock.withLock { failRead } }
        set { lock.withLock { failRead = newValue } }
    }

    /// Every clear throws and leaves the record.
    var clearFails: Bool {
        get { lock.withLock { failClear } }
        set { lock.withLock { failClear = newValue } }
    }

    /// The record, whatever `readFails` says.
    var stored: CodexSwitchJournal? { lock.withLock { record } }

    func read() throws -> CodexSwitchJournal? {
        try lock.withLock {
            if failRead { throw Failed() }
            return record
        }
    }

    func write(_ journal: CodexSwitchJournal) throws {
        try lock.withLock {
            if writeFails { throw Failed() }
            record = journal
            writeCount += 1
        }
        onWrite?()
    }

    /// Like deleting the file: an unreadable journal cleared is no journal.
    func clear() throws {
        try lock.withLock {
            if failClear { throw Failed() }
            record = nil
            failRead = false
        }
    }
}
