import XCTest
@testable import Ration

/// `codex-switch.json`, the switch log and the switch journal (spec §4.1, §4.2).
final class CodexStateTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_790_100_000)

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoder.encode(value))
    }

    func testDefaults() {
        let state = CodexState()
        XCTAssertFalse(state.autoSwitchEnabled, "off until the user turns it on")
        XCTAssertEqual(state.rule, ClaudeCodeAutoSwitch.Rule(percent: 75, kind: .weekly), "the default: 75% of the weekly limit")
        XCTAssertFalse(state.autoSwitchPaused)
        XCTAssertTrue(state.notify)
        XCTAssertTrue(state.links.isEmpty)
        XCTAssertTrue(state.dismissedPrompts.isEmpty)
        XCTAssertTrue(state.keptUnlinked.isEmpty)
        XCTAssertNil(state.status)
        XCTAssertNil(state.noRoomNotified)
        XCTAssertNil(state.lastSwitchTo)
        XCTAssertNil(state.lastSwitchAt)
        XCTAssertFalse(state.configurationAcknowledged, "the user confirms Codex's configuration before automatic switching")
        XCTAssertTrue(state.staleLogins.isEmpty)
    }

    /// Tolerant: an older or partial file keeps what it has and defaults the rest.
    func testDecodesAnEmptyOrPartialFile() throws {
        XCTAssertEqual(try decoder.decode(CodexState.self, from: Data("{}".utf8)), CodexState())
        let partial = try decoder.decode(CodexState.self, from: Data(#"""
            {"autoSwitchEnabled":true,"configurationAcknowledged":true,"lastSwitchTo":"acct-B|user-2","future":1}
            """#.utf8))
        XCTAssertTrue(partial.autoSwitchEnabled)
        XCTAssertTrue(partial.configurationAcknowledged)
        XCTAssertEqual(partial.lastSwitchTo, "acct-B|user-2")
        XCTAssertTrue(partial.notify)
    }

    /// A field this build cannot read falls back alone; the rest is kept.
    func testABadRuleAndAnUnknownStatusFallBackAlone() throws {
        let id = UUID()
        let state = try decoder.decode(CodexState.self, from: Data(#"""
            {"links":{"acct-A|user-1":"\#(id.uuidString)"},"autoSwitchEnabled":true,"rule":"often",
             "status":{"exploded":{"at":"2026-10-11T18:00:00Z"}},"notify":false}
            """#.utf8))
        XCTAssertEqual(state.rule, ClaudeCodeAutoSwitch.Rule())
        XCTAssertNil(state.status)
        XCTAssertEqual(state.links, ["acct-A|user-1": id])
        XCTAssertTrue(state.autoSwitchEnabled)
        XCTAssertFalse(state.notify)
    }

    func testEveryStatusRoundTrips() throws {
        let all: [CodexStatus] = [
            .switched(at: at, from: "acct-A|user-1", to: "acct-B|user-2", automatic: true),
            .switched(at: at, from: "acct-A|user-1", to: "acct-B|user-2", automatic: false, verified: false), .failed(at: at), .conflict(at: at),
            .needsAttention(at: at), .noRoom(at: at), .waiting(at: at), .paused(at: at),
            .stale(at: at, login: "acct-B|user-2"), .damaged(at: at),
        ]
        for status in all { XCTAssertEqual(try roundTrip(status), status) }
    }

    func testTheWholeStateRoundTrips() throws {
        var state = CodexState()
        state.links = ["acct-A|user-1": UUID()]
        state.dismissedPrompts = ["acct-C|user-3"]
        state.keptUnlinked = ["acct-D|user-4"]
        state.autoSwitchEnabled = true
        state.rule = ClaudeCodeAutoSwitch.Rule(percent: 60, kind: .weekly)
        state.autoSwitchPaused = true
        state.notify = false
        state.status = .stale(at: at, login: "acct-B|user-2")
        state.noRoomNotified = ["acct-B|user-2"]
        state.lastSwitchTo = "acct-B|user-2"
        state.lastSwitchAt = at
        state.configurationAcknowledged = true
        state.staleLogins = ["acct-B|user-2"]
        XCTAssertEqual(try roundTrip(state), state)
    }

    /// The stale copies, read leniently like every other field.
    func testStaleLoginsDecodeLeniently() throws {
        let state = try decoder.decode(CodexState.self, from: Data(#"{"staleLogins":["acct-B|user-2"],"notify":false}"#.utf8))
        XCTAssertEqual(state.staleLogins, ["acct-B|user-2"])
        let bad = try decoder.decode(CodexState.self, from: Data(#"{"staleLogins":"acct-B","notify":false}"#.utf8))
        XCTAssertEqual(bad.staleLogins, [])
        XCTAssertFalse(bad.notify, "the rest is kept")
    }

    func testTheLogKeepsTheNewest500() throws {
        var log: [CodexSwitchLogEntry] = []
        for index in 0..<503 {
            log = CodexSwitchLogEntry.appending(
                .init(at: Date(timeIntervalSince1970: Double(index)), from: "a|1", to: "b|2", automatic: index.isMultiple(of: 2),
                      rule: index.isMultiple(of: 2) ? ClaudeCodeAutoSwitch.Rule() : nil), to: log)
        }
        XCTAssertEqual(log.count, 500)
        XCTAssertEqual(log.first?.at, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(log.last?.at, Date(timeIntervalSince1970: 502))
        XCTAssertEqual(CodexSwitchLogEntry.fileName, "codex-switches.json")
        XCTAssertEqual(try roundTrip(log), log)
    }
}

/// The journal file in a temporary folder.
final class CodexJournalFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "CodexJournalFileTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testRoundTripsAndClears() throws {
        let file = CodexJournalFile(url: folder.appending(path: "nested/codex-switch-journal.json"))
        XCTAssertNil(try file.read())
        XCTAssertNoThrow(try file.clear(), "clearing nothing is fine")
        let record = CodexSwitchJournal(startedAt: Date(timeIntervalSince1970: 1_790_100_000), from: "acct-A|user-1", to: "acct-B|user-2",
                                        fromSavedAt: Date(timeIntervalSince1970: 1_790_000_000))
        try file.write(record)
        XCTAssertEqual(try file.read(), record)
        let unremembered = CodexSwitchJournal(startedAt: record.startedAt, from: "acct-A|user-1", to: "acct-B|user-2", fromSavedAt: nil)
        try file.write(unremembered)
        XCTAssertEqual(try file.read(), unremembered)
        try file.clear()
        XCTAssertNil(try file.read())
    }

    /// No bytes, no token: the remembered copy it names is the rollback source.
    func testHoldsNoBytes() throws {
        let url = folder.appending(path: "codex-switch-journal.json")
        try CodexJournalFile(url: url).write(CodexSwitchJournal(startedAt: .now, from: "a|1", to: "b|2", fromSavedAt: .now))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["startedAt", "from", "to", "fromSavedAt"])
    }

    /// A journal that is there but cannot be read or decoded is
    /// not "no journal" — it throws, and the switcher treats it as unresolved.
    func testAnUnreadableJournalThrows() throws {
        let url = folder.appending(path: "codex-switch-journal.json")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{".utf8).write(to: url)
        XCTAssertThrowsError(try CodexJournalFile(url: url).read(), "corrupt")

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try CodexJournalFile(url: url).read(), "not a file")
    }
}
