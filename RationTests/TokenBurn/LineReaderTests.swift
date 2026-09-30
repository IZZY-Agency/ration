import XCTest
@testable import Ration

final class LineReaderTests: XCTestCase {
    private var file: URL!

    override func setUpWithError() throws {
        file = try makeTempDirectory().appending(path: "log.jsonl")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    private func write(_ text: String, append: Bool = false) throws {
        if append, let handle = try? FileHandle(forWritingTo: file) {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
            try handle.close()
        } else {
            try Data(text.utf8).write(to: file)
        }
    }

    private func read(_ reader: LineReader = LineReader(), from offset: Int64 = 0) throws -> ([String], LineReader.Outcome) {
        let fd = open(file.path(percentEncoded: false), O_RDONLY)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let size = Int64((try FileManager.default.attributesOfItem(atPath: file.path(percentEncoded: false))[.size] as! NSNumber).int64Value)
        var lines: [String] = []
        let outcome = try reader.read(fd: fd, from: offset, to: size) { line, _ in lines.append(String(decoding: line, as: UTF8.self)); return false }
        return (lines, outcome)
    }

    func testCheckpointStopsAfterTheLastNewline() throws {
        try write("aa\nbb\ncc")
        let (lines, outcome) = try read()
        XCTAssertEqual(lines, ["aa", "bb"])
        XCTAssertEqual(outcome, LineReader.Outcome(checkpoint: 6, oversized: 0, pendingBytes: 2))
    }

    /// A line appended in two pieces is read once, whole.
    func testUnfinishedLineIsReadWholeOnceItsNewlineArrives() throws {
        try write("aa\nb")
        let (first, one) = try read()
        XCTAssertEqual(first, ["aa"])
        try write("cd\n", append: true)
        let (second, two) = try read(from: one.checkpoint)
        XCTAssertEqual(second, ["bcd"])
        XCTAssertEqual(two.checkpoint, 7)
        XCTAssertEqual(two.pendingBytes, 0)
    }

    func testLinesLongerThanAChunk() throws {
        try write("abcdefghij\nklmnopqrstuv\nx\n")
        let (lines, outcome) = try read(LineReader(chunkSize: 4, maxLine: 1 << 20))
        XCTAssertEqual(lines, ["abcdefghij", "klmnopqrstuv", "x"])
        XCTAssertEqual(outcome.checkpoint, 26)
    }

    func testOversizedLineIsSkippedCountedAndPassed() throws {
        try write(String(repeating: "z", count: 40) + "\nok\n")
        let (lines, outcome) = try read(LineReader(chunkSize: 8, maxLine: 16))
        XCTAssertEqual(lines, ["ok"])
        XCTAssertEqual(outcome, LineReader.Outcome(checkpoint: 44, oversized: 1, pendingBytes: 0))
    }

    func testEmptyLinesAreNotPassed() throws {
        try write("\n\nx\n")
        let (lines, outcome) = try read()
        XCTAssertEqual(lines, ["x"])
        XCTAssertEqual(outcome.checkpoint, 4)
    }

    func testNeverReadsPastTheGivenEnd() throws {
        try write("aa\nbb\n")
        let fd = open(file.path(percentEncoded: false), O_RDONLY)
        defer { close(fd) }
        var lines: [String] = []
        let outcome = try LineReader().read(fd: fd, from: 0, to: 3) { line, _ in lines.append(String(decoding: line, as: UTF8.self)); return false }
        XCTAssertEqual(lines, ["aa"])
        XCTAssertEqual(outcome.checkpoint, 3)
    }

    /// A line over the limit that ends inside the chunk that
    /// crossed the limit is still skipped, never handed on.
    func testCompleteLineOverTheLimitIsSkipped() throws {
        try write("12345678901234567\nok\n")
        let (lines, outcome) = try read(LineReader(chunkSize: 8, maxLine: 16))
        XCTAssertEqual(lines, ["ok"])
        XCTAssertEqual(outcome, LineReader.Outcome(checkpoint: 21, oversized: 1, pendingBytes: 0))
    }

    /// Each line reports the offset just after its newline: the scanner's
    /// checkpoint for a commit in the middle of a file.
    func testEachLineReportsWhereItEnds() throws {
        try write("aa\nbbb\n\nc")
        let fd = open(file.path(percentEncoded: false), O_RDONLY)
        defer { close(fd) }
        var ends: [Int64] = []
        _ = try LineReader().read(fd: fd, from: 0, to: 10) { _, end in ends.append(end); return false }
        XCTAssertEqual(ends, [3, 7])
    }

    func testDefaultLimitIsEightMebibytes() {
        XCTAssertEqual(LineReader().maxLine, 8 << 20, "longest reply line seen: 541 KB; longest line of any kind: 2.4 MB")
    }

    /// A full batch stops the read right after its line; the next read resumes there.
    func testCallbackCanStopTheReadAfterALine() throws {
        try write("aa\nbb\ncc\n")
        let fd = open(file.path(percentEncoded: false), O_RDONLY)
        defer { close(fd) }
        var lines: [String] = []
        let first = try LineReader().read(fd: fd, from: 0, to: 9) { line, _ in lines.append(String(decoding: line, as: UTF8.self)); return lines.count == 2 }
        XCTAssertEqual(first.checkpoint, 6)
        XCTAssertTrue(first.stopped)
        let rest = try LineReader().read(fd: fd, from: first.checkpoint, to: 9) { line, _ in lines.append(String(decoding: line, as: UTF8.self)); return false }
        XCTAssertEqual(lines, ["aa", "bb", "cc"])
        XCTAssertEqual(rest.checkpoint, 9)
        XCTAssertFalse(rest.stopped)
    }
}
