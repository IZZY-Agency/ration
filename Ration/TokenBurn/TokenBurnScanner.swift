import CryptoKit
import Darwin
import Foundation

/// Counts Claude Code usage from the session logs under one folder (spec §5.1).
/// Opens only `*.jsonl` regular files, keeps no path, and commits each file on
/// its own: a quit or crash mid-scan loses nothing and counts nothing twice.
actor TokenBurnScanner {
    struct Report: Equatable, Sendable {
        var filesSeen = 0
        var filesRead = 0
        var filesUnchanged = 0
        var filesUnreadable = 0
        var repliesCounted = 0
        var duplicatesIgnored = 0
        var malformedLines = 0
        var oversizedLines = 0
        var pendingBytes: Int64 = 0
        var bytesRead: Int64 = 0
        var stoppedEarly = false
    }

    private let store: TokenBurnStore
    private let reader: LineReader
    private let decoder = ReplyLineDecoder()

    private let batchSize: Int

    init(databaseURL: URL, reader: LineReader = LineReader(), batchSize: Int = 5_000) throws {
        store = try TokenBurnStore(url: databaseURL)
        self.reader = reader
        self.batchSize = batchSize
    }

    func close() { store.close() }

    func summary() throws -> TokenBurnStore.Summary { try store.summary() }

    func totals(from start: Date, to end: Date) throws -> [TokenBurnStore.UsageTotal] {
        try store.totals(fromMinute: Self.minute(start, .down), toMinute: Self.minute(end, .up))
    }

    func minuteTotals(from start: Date, to end: Date) throws -> [(minute: Int64, total: TokenBurnStore.UsageTotal)] {
        try store.minuteTotals(fromMinute: Self.minute(start, .down), toMinute: Self.minute(end, .up))
    }

    private static func minute(_ date: Date, _ rule: FloatingPointRoundingRule) -> Int64 {
        let value = (date.timeIntervalSince1970 / 60).rounded(rule)
        guard value.isFinite else { return value < 0 ? .min : .max }
        return Int64(max(min(value, Double(Int64.max / 2)), Double(Int64.min / 2)))
    }

    // Sign-in spans and bindings: the store is the scanner's alone.
    func observe(_ identity: SignInIdentity?, fetchedAt: Date?, at date: Date) throws {
        try store.observe(identity, fetchedAt: fetchedAt, at: date)
    }
    func signInSpans() throws -> [SignInSpan] { try store.signInSpans() }
    func setOrganization(_ organization: String, for account: UUID, at date: Date) throws {
        try store.setOrganization(organization, for: account, at: date)
    }
    func organizationBindings() throws -> [UUID: String] { try store.organizationBindings() }
    func removeBinding(account: UUID) throws { try store.removeBinding(account: account) }
    func recordConfigWrite(at date: Date) throws { try store.recordConfigWrite(at: date) }
    func recordLoggedSwitch(at date: Date) throws { try store.recordLoggedSwitch(at: date) }
    func configWrites() throws -> [Date] { try store.configWrites() }
    func deleteUsage(minutes: [Int64]) throws { try store.deleteUsage(minutes: minutes) }
    func deleteSpans(of identities: Set<SignInIdentity>) throws { try store.deleteSpans(of: identities) }

    private struct StopEarly: Error {}

    /// Ends the pass after that many commits (a file, or a batch inside one),
    /// as a kill would (tests and `TokenBurnCorpusProbe`). `progress` gets
    /// (files done, files in this pass): (0, M) first, then once per file.
    func scan(root: URL, stopAfterCommits: Int? = nil,
              progress: (@Sendable (Int, Int) -> Void)? = nil) throws -> Report {
        var report = Report()
        let known = try store.fileStates()
        var seen = Set<TokenBurnStore.FileIdentity>()
        var commits = 0
        let files = Self.logFiles(under: root)
        progress?(0, files.count)
        do {
            for (index, url) in files.enumerated() {
                try Task.checkCancellation()
                defer { progress?(index + 1, files.count) }
                report.filesSeen += 1
                let fd = open(url.path(percentEncoded: false), O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { report.filesUnreadable += 1; continue }
                defer { Darwin.close(fd) }
                var info = stat()
                guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { report.filesUnreadable += 1; continue }
                let identity = TokenBurnStore.FileIdentity(
                    device: Int64(info.st_dev), inode: Int64(info.st_ino),
                    birth: Int64(info.st_birthtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_birthtimespec.tv_nsec))
                seen.insert(identity)
                let size = Int64(info.st_size)
                let mtime = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
                let previous = known[identity]
                if let previous, !previous.gone, previous.size == size, previous.mtime == mtime {
                    report.filesUnchanged += 1
                    continue
                }
                // Carry on after the checkpoint only while the bytes before it
                // are the ones read last time; otherwise the file was rewritten
                // and is read again from the top (counted replies stay counted,
                // so nothing doubles).
                var start: Int64 = 0
                if let previous, previous.checkpoint > 0, previous.checkpoint <= size,
                   Self.tail(fd, before: previous.checkpoint) == previous.tail {
                    start = previous.checkpoint
                }
                var pass = TokenBurnStore.FilePass(identity: identity, rebuild: (previous?.checkpoint ?? 0) > 0 && start == 0,
                                                   checkpoint: start, size: start)
                // A batch records its checkpoint as the size and no time, so a
                // pass cut short is never mistaken for an unchanged file.
                func commit(through checkpoint: Int64, size recordedSize: Int64, mtime recordedTime: Int64, oversized: Int) throws {
                    pass.checkpoint = checkpoint
                    pass.size = recordedSize
                    pass.mtime = recordedTime
                    pass.oversized = oversized
                    pass.tail = Self.tail(fd, before: checkpoint) ?? 0
                    let result = try store.commit(pass)
                    report.repliesCounted += result.counted
                    report.duplicatesIgnored += result.duplicates
                    report.malformedLines += pass.malformed
                    pass.replies.removeAll(keepingCapacity: true)
                    pass.malformed = 0
                    pass.rebuild = false
                    commits += 1
                    if let stopAfterCommits, commits >= stopAfterCommits { throw StopEarly() }
                }
                let decoder = self.decoder
                let batchSize = self.batchSize
                var position = start
                var oversized = 0
                var outcome: LineReader.Outcome
                do {
                    while true {
                        outcome = try reader.read(fd: fd, from: position, to: size) { line, _ in
                            switch decoder.decode(line) {
                            case .reply(let reply): pass.replies.append(reply)
                            case .malformed: pass.malformed += 1
                            case .notAReply: break
                            }
                            return pass.replies.count >= batchSize
                        }
                        oversized += outcome.oversized
                        guard outcome.stopped else { break }
                        // A full batch: commit it with its own checkpoint.
                        try Task.checkCancellation()
                        try commit(through: outcome.checkpoint, size: outcome.checkpoint, mtime: 0, oversized: outcome.oversized)
                        position = outcome.checkpoint
                    }
                } catch is POSIXError {
                    // Batches already committed stay; the rest is read next pass.
                    report.filesUnreadable += 1
                    continue
                }
                try Task.checkCancellation()
                try commit(through: outcome.checkpoint, size: size, mtime: mtime, oversized: outcome.oversized)
                report.filesRead += 1
                report.bytesRead += size - start
                report.oversizedLines += oversized
                report.pendingBytes += outcome.pendingBytes
            }
        } catch is StopEarly {
            report.stoppedEarly = true
            return report
        }
        try store.markGone(notIn: seen)
        return report
    }

    /// A hash of up to 4 KiB just before `offset`: whether the bytes before a
    /// checkpoint are still the ones read. Records can end in the same few
    /// dozen bytes, so the window spans whole records. A hash, never the bytes.
    private static func tail(_ fd: Int32, before offset: Int64) -> Int64? {
        guard offset > 0 else { return 0 }
        let length = Int(min(4_096, offset))
        var bytes = [UInt8](repeating: 0, count: length)
        let got = bytes.withUnsafeMutableBytes { pread(fd, $0.baseAddress, length, off_t(offset - Int64(length))) }
        guard got == length else { return nil }
        return SHA256.hash(data: bytes).withUnsafeBytes { Int64(bitPattern: $0.loadUnaligned(as: UInt64.self)) }
    }

    /// `*.jsonl` regular files under `root`; symlinks are skipped, never followed.
    static func logFiles(under root: URL) -> [URL] {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else { return [] }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            files.append(url)
        }
        return files.sorted { $0.path(percentEncoded: false) < $1.path(percentEncoded: false) }
    }
}
