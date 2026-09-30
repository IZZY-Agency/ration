import XCTest
@testable import Ration

final class TokenBurnScannerTests: XCTestCase {
    private var root: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        let base = try makeTempDirectory()
        root = base.appending(path: "projects", directoryHint: .isDirectory)
        dbURL = base.appending(path: "token-burn.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    @discardableResult
    private func log(_ relative: String, _ lines: [String], newlineAtEnd: Bool = true, append: Bool = false) throws -> URL {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = lines.joined(separator: "\n") + (newlineAtEnd ? "\n" : "")
        if append, let handle = try? FileHandle(forWritingTo: url) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: url)
        }
        return url
    }

    private func line(_ id: String, input: Int = 100) -> String { TokenBurnFixtures.line(id: id, request: "r-\(id)", input: input) }

    func testScansNestedLogsOnlyAndNeverFollowsSymlinks() async throws {
        try log("-Users-me-app/s1.jsonl", [line("1"), line("1")])
        try log("-Users-me-app/s1/subagents/agent-a.jsonl", [line("2")])
        try log("-Users-me-app/notes.txt", [line("3")])
        let outside = try makeTempDirectory().appending(path: "elsewhere.jsonl")
        try Data((line("4") + "\n").utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "-Users-me-app/link.jsonl"), withDestinationURL: outside)
        let scanner = try TokenBurnScanner(databaseURL: dbURL)
        let report = try await scanner.scan(root: root)
        XCTAssertEqual(report.filesSeen, 2)
        XCTAssertEqual(report.repliesCounted, 2)
        XCTAssertEqual(report.duplicatesIgnored, 1)
    }

    /// Progress reads "counting… N of M files" during a pass.
    func testProgressCountsEveryFile() async throws {
        try log("a/s1.jsonl", [line("1")])
        try log("a/s1/subagents/x.jsonl", [line("2")])
        try log("b/s2.jsonl", [line("3")])
        let scanner = try TokenBurnScanner(databaseURL: dbURL)
        let seen = ProgressLog()
        _ = try await scanner.scan(root: root, progress: { done, total in seen.add(done, total) })
        XCTAssertEqual(seen.all.last?.done, 3)
        XCTAssertEqual(Set(seen.all.map(\.total)), [3])
        XCTAssertEqual(seen.all.map(\.done), [0, 1, 2, 3], "starts at 0 of M, then one step per file")
    }

    /// The store is the scanner's alone; sign-in spans and bindings go through it.
    func testSignInSpansAndBindingsGoThroughTheScanner() async throws {
        let scanner = try TokenBurnScanner(databaseURL: dbURL)
        let identity = SignInIdentity(accountUUID: "acc-1", organizationUUID: "org-1", billingType: nil)
        try await scanner.observe(identity, fetchedAt: nil, at: Date(timeIntervalSince1970: 100))
        let spans = try await scanner.signInSpans()
        XCTAssertEqual(spans.map(\.identity), [identity])
        let account = UUID()
        try await scanner.setOrganization("org-1", for: account, at: Date(timeIntervalSince1970: 100))
        let bindings = try await scanner.organizationBindings()
        XCTAssertEqual(bindings, [account: "org-1"])
        try await scanner.removeBinding(account: account)
        let after = try await scanner.organizationBindings()
        XCTAssertEqual(after, [:])
    }

    func testSecondScanReadsOnlyTheNewBytes() async throws {
        let url = try log("p/s.jsonl", [line("1")])
        let scanner = try TokenBurnScanner(databaseURL: dbURL)
        _ = try await scanner.scan(root: root)
        let before = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as! Int
        try log("p/s.jsonl", [line("2")], append: true)
        let after = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.size] as! Int
        let second = try await scanner.scan(root: root)
        XCTAssertEqual(second.bytesRead, Int64(after - before))
        XCTAssertEqual(second.repliesCounted, 1)
        let third = try await scanner.scan(root: root)
        XCTAssertEqual(third.filesUnchanged, 1)
        let summaryNow = try await scanner.summary()
        XCTAssertEqual(summaryNow.replies, 2)
    }

    /// A line caught mid-write counts once, when it is finished.
    func testLineCaughtMidWriteCountsOnceWhenFinished() async throws {
        let whole = line("1")
        let cut = whole.index(whole.startIndex, offsetBy: whole.count / 2)
        try log("p/s.jsonl", [String(whole[..<cut])], newlineAtEnd: false)
        let scanner = try TokenBurnScanner(databaseURL: dbURL)
        let first = try await scanner.scan(root: root)
        XCTAssertEqual(first.repliesCounted, 0)
        XCTAssertEqual(first.malformedLines, 0, "an unfinished line is pending, not malformed")
        XCTAssertGreaterThan(first.pendingBytes, 0)
        try log("p/s.jsonl", [String(whole[cut...])], append: true)
        let second = try await scanner.scan(root: root)
        XCTAssertEqual(second.repliesCounted, 1)
        let summaryNow = try await scanner.summary()
        XCTAssertEqual(summaryNow.malformedLines, 0)
    }

    /// A reply in a parent log and its subagent copy counts once.
    func testParentAndSubagentCopyCountOnce() async throws {
        try log("p/s.jsonl", [line("1"), line("2")])
        try log("p/s/subagents/a.jsonl", [line("2"), line("3")])
        let scanner = try TokenBurnScanner(databaseURL: dbURL)
        _ = try await scanner.scan(root: root)
        let summaryNow = try await scanner.summary()
        XCTAssertEqual(summaryNow.replies, 3)
    }

    /// A kill between files, then a restart, equals one clean scan.
    func testStopMidScanThenResumeEqualsAFullScan() async throws {
        for index in 0..<6 { try log("p/s\(index).jsonl", [line("a\(index)"), line("b\(index)", input: index), line("shared")]) }
        let interrupted = try TokenBurnScanner(databaseURL: dbURL)
        let stopped = try await interrupted.scan(root: root, stopAfterCommits: 2)
        XCTAssertTrue(stopped.stoppedEarly)
        await interrupted.close()
        let resumed = try TokenBurnScanner(databaseURL: dbURL)
        _ = try await resumed.scan(root: root)
        let clean = try TokenBurnScanner(databaseURL: dbURL.deletingLastPathComponent().appending(path: "clean.sqlite"))
        _ = try await clean.scan(root: root)
        let a = try await resumed.summary(), b = try await clean.summary()
        XCTAssertEqual(a.replies, b.replies)
        XCTAssertEqual(a.tokens, b.tokens)
        XCTAssertEqual(a.replies, 13)
    }

    func testShrunkFileKeepsWhatItCountedAndAddsItsNewReplies() async throws {
        let url = try log("p/s.jsonl", [line("1"), line("2")])
        let scanner = try TokenBurnScanner(databaseURL: dbURL)
        _ = try await scanner.scan(root: root)
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((line("3") + "\n").utf8))
        try handle.close()
        _ = try await scanner.scan(root: root)
        let summary = try await scanner.summary()
        XCTAssertEqual(summary.replies, 3)
        XCTAssertEqual(summary.tokens.input, 300)
    }

    func testDeletedLogKeepsItsCounts() async throws {
        let url = try log("p/s.jsonl", [line("1")])
        let scanner = try TokenBurnScanner(databaseURL: dbURL)
        _ = try await scanner.scan(root: root)
        try FileManager.default.removeItem(at: url)
        _ = try await scanner.scan(root: root)
        let summary = try await scanner.summary()
        XCTAssertEqual(summary.replies, 1)
        XCTAssertEqual(summary.goneFiles, 1)
    }

    func testMalformedLinesAreCountedPerFile() async throws {
        try log("p/s.jsonl", [#"{"type":"assistant","message":"#, line("1")])
        let scanner = try TokenBurnScanner(databaseURL: dbURL)
        let report = try await scanner.scan(root: root)
        XCTAssertEqual(report.malformedLines, 1)
        XCTAssertEqual(report.repliesCounted, 1)
    }

    private func rewriteInPlace(_ url: URL, _ lines: [String], bumpModificationTime: Bool = true) throws {
        let handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data((lines.joined(separator: "\n") + "\n").utf8))
        try handle.close()
        if bumpModificationTime {
            let later = Date().addingTimeInterval(5)
            try FileManager.default.setAttributes([.modificationDate: later], ofItemAtPath: url.path(percentEncoded: false))
        }
    }

    /// The file that first counted a reply loses it; another
    /// file still has it. It stays counted.
    func testReplyStaysCountedWhenTheFileThatCountedItLosesIt() async throws {
        let a = try log("p/a.jsonl", [line("x")])
        try log("p/b.jsonl", [line("x"), line("y")])
        let scanner = try TokenBurnScanner(databaseURL: dbURL)
        _ = try await scanner.scan(root: root)
        try rewriteInPlace(a, [line("z")])
        _ = try await scanner.scan(root: root)
        let summary = try await scanner.summary()
        XCTAssertEqual(summary.replies, 3)
    }

    /// A log replaced by a new file at the same path keeps
    /// what it counted and counts only its new replies.
    func testReplacedLogCountsOnlyItsNewReplies() async throws {
        let url = try log("p/s.jsonl", [line("1")])
        let scanner = try TokenBurnScanner(databaseURL: dbURL)
        _ = try await scanner.scan(root: root)
        try Data((line("1") + "\n" + line("2") + "\n").utf8).write(to: url, options: .atomic)
        let report = try await scanner.scan(root: root)
        XCTAssertEqual(report.repliesCounted, 1)
        XCTAssertEqual(report.duplicatesIgnored, 1)
        let summary = try await scanner.summary()
        XCTAssertEqual(summary.replies, 2)
    }

    /// A rewrite that keeps the size is still noticed.
    func testSameSizeRewriteIsNoticed() async throws {
        let url = try log("p/s.jsonl", [line("1")])
        let scanner = try TokenBurnScanner(databaseURL: dbURL)
        _ = try await scanner.scan(root: root)
        try rewriteInPlace(url, [line("2")])
        _ = try await scanner.scan(root: root)
        let summary = try await scanner.summary()
        XCTAssertEqual(summary.replies, 2)
    }

    /// A rewrite that grows the file is not mistaken for an
    /// append: it is read from the top.
    func testRewriteThatGrowsTheFileIsReadFromTheTop() async throws {
        let url = try log("p/s.jsonl", [line("1")])
        let scanner = try TokenBurnScanner(databaseURL: dbURL)
        _ = try await scanner.scan(root: root)
        try rewriteInPlace(url, [line("2"), line("3")])
        let report = try await scanner.scan(root: root)
        XCTAssertEqual(report.malformedLines, 0)
        let summary = try await scanner.summary()
        XCTAssertEqual(summary.replies, 3)
    }

    /// A file commits in batches, each with its own
    /// checkpoint, so a stop mid-file loses and doubles nothing.
    func testBatchesCommitInsideAFileAndResumeCleanly() async throws {
        try log("p/s.jsonl", (1...5).map { line("\($0)") })
        let first = try TokenBurnScanner(databaseURL: dbURL, batchSize: 2)
        let stopped = try await first.scan(root: root, stopAfterCommits: 1)
        XCTAssertTrue(stopped.stoppedEarly)
        let partial = try await first.summary()
        XCTAssertEqual(partial.replies, 2)
        await first.close()
        let second = try TokenBurnScanner(databaseURL: dbURL, batchSize: 2)
        let rest = try await second.scan(root: root)
        XCTAssertEqual(rest.repliesCounted, 3)
        XCTAssertEqual(rest.duplicatesIgnored, 0)
    }
}

private final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(done: Int, total: Int)] = []
    func add(_ done: Int, _ total: Int) { lock.withLock { entries.append((done, total)) } }
    var all: [(done: Int, total: Int)] { lock.withLock { entries } }
}
