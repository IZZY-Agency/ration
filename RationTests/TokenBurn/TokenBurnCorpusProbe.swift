import XCTest
@testable import Ration

/// Checks the scanner against an independent count, and a scan stopped part
/// way and resumed against a full one (spec §3). Reads the real Claude Code
/// logs READ-ONLY into a temporary store, and only when asked:
///
///   TEST_RUNNER_TOKEN_BURN_CORPUS=~/.claude/projects
///   TEST_RUNNER_TOKEN_BURN_BEFORE_HOUR=<hours since 1970, UTC>
///   TEST_RUNNER_TOKEN_BURN_EXPECTED=<corpus-count.py --json --before-hour=… output>
///
/// Both counters compare only replies timestamped before that hour, so sessions
/// writing while the probe runs cannot move the numbers. Prints aggregates only.
final class TokenBurnCorpusProbe: XCTestCase {
    func testScannerMatchesTheIndependentCount() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let corpus = env["TOKEN_BURN_CORPUS"], let expectedPath = env["TOKEN_BURN_EXPECTED"],
              let beforeHour = env["TOKEN_BURN_BEFORE_HOUR"].flatMap(Double.init) else {
            throw XCTSkip("runs only with TEST_RUNNER_TOKEN_BURN_CORPUS, _EXPECTED and _BEFORE_HOUR")
        }
        let expected = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: expectedPath))) as! [String: Int]
        let root = URL(fileURLWithPath: corpus, isDirectory: true)
        let cutoff = Date(timeIntervalSince1970: beforeHour * 3600)
        let work = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: work) }

        let peakBefore = Self.peakResidentMB()
        let clock = ContinuousClock()
        let full = try TokenBurnScanner(databaseURL: work.appending(path: "full.sqlite"))
        var report = TokenBurnScanner.Report()
        let elapsed = try await clock.measure { report = try await full.scan(root: root) }
        let peakAfter = Self.peakResidentMB()
        let all = try await full.summary()
        let upToCutoff = Self.sum(try await full.totals(from: .distantPast, to: cutoff))
        print("PROBE full scan: \(elapsed); files \(report.filesSeen), read \(report.filesRead), unreadable \(report.filesUnreadable); replies \(all.replies), duplicates \(report.duplicatesIgnored), malformed \(report.malformedLines), oversized \(report.oversizedLines), pending bytes \(report.pendingBytes); peak RSS \(peakBefore) → \(peakAfter) MB")
        print("PROBE before cutoff: replies \(upToCutoff.replies); input \(upToCutoff.tokens.input), output \(upToCutoff.tokens.output), cache read \(upToCutoff.tokens.cacheRead), cache write 5m \(upToCutoff.tokens.cacheWrite5m) 1h \(upToCutoff.tokens.cacheWrite1h) unsplit \(upToCutoff.tokens.cacheWriteUnsplit), searches \(all.webSearches) (all)")
        let value = TokenBurnPricing.value(of: try await full.totals(from: .distantPast, to: cutoff))
        print("PROBE list-price value before cutoff: \(value.cents / 100) USD; unpriced tokens \(value.unpricedTokens); complete \(value.isComplete)")

        XCTAssertEqual(upToCutoff.replies, expected["unique_replies"])
        XCTAssertEqual(upToCutoff.tokens.input, expected["tok_input"])
        XCTAssertEqual(upToCutoff.tokens.output, expected["tok_output"])
        XCTAssertEqual(upToCutoff.tokens.cacheRead, expected["tok_cache_read_input_tokens"])
        XCTAssertEqual(upToCutoff.tokens.cacheWrite5m + upToCutoff.tokens.cacheWrite1h + upToCutoff.tokens.cacheWriteUnsplit,
                       expected["tok_cache_creation_input_tokens"])

        // Replay: stop after a third of the files, reopen, finish.
        let replayURL = work.appending(path: "replay.sqlite")
        let first = try TokenBurnScanner(databaseURL: replayURL)
        _ = try await first.scan(root: root, stopAfterCommits: max(1, report.filesSeen / 3))
        await first.close()
        let second = try TokenBurnScanner(databaseURL: replayURL)
        _ = try await second.scan(root: root)
        let replayed = Self.sum(try await second.totals(from: .distantPast, to: cutoff))
        XCTAssertEqual(replayed.replies, upToCutoff.replies)
        XCTAssertEqual(replayed.tokens, upToCutoff.tokens)

        // A second pass reads only what sessions appended meanwhile.
        let again = try await full.scan(root: root)
        print("PROBE rescan: \(again.filesUnchanged) unchanged, \(again.filesRead) read, \(again.bytesRead) bytes")
        XCTAssertGreaterThan(again.filesUnchanged, report.filesSeen * 9 / 10)
    }

    private static func sum(_ totals: [TokenBurnStore.UsageTotal]) -> (replies: Int, tokens: TokenCounts) {
        var tokens = TokenCounts()
        var replies = 0
        for total in totals {
            tokens += total.tokens
            replies += total.replies
        }
        return (replies, tokens)
    }

    private static func peakResidentMB() -> Int {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Int(usage.ru_maxrss / 1_048_576)
    }
}
