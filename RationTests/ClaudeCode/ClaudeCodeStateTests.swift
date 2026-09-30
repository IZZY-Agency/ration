import XCTest
@testable import Ration

final class ClaudeCodeStateTests: XCTestCase {
    private func roundTrip<T: Codable>(_ value: T) throws -> T {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: encoder.encode(value))
    }

    func testDefaults() {
        let state = ClaudeCodeState()
        XCTAssertFalse(state.autoSwitchEnabled, "off until the user turns it on")
        XCTAssertEqual(state.rule, ClaudeCodeAutoSwitch.Rule(percent: 75, kind: .weekly), "the default: 75% of the weekly limit")
        XCTAssertFalse(state.autoSwitchPaused)
        XCTAssertTrue(state.notify)
        XCTAssertTrue(state.links.isEmpty)
        XCTAssertNil(state.status)
    }

    /// Tolerant: an older or partial file keeps what it has and defaults the rest.
    func testDecodesAnEmptyOrPartialFile() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(ClaudeCodeState.self, from: Data("{}".utf8)), ClaudeCodeState())
        let partial = try decoder.decode(ClaudeCodeState.self, from: Data(#"{"autoSwitchEnabled":true,"future":1,"rule":{"percent":60,"kind":"fiveHour"}}"#.utf8))
        XCTAssertTrue(partial.autoSwitchEnabled)
        XCTAssertEqual(partial.rule, ClaudeCodeAutoSwitch.Rule(percent: 60, kind: .fiveHour))
        XCTAssertTrue(partial.notify)
    }

    func testEveryStatusRoundTrips() throws {
        let at = Date(timeIntervalSince1970: 1_790_100_000)
        let all: [ClaudeCodeStatus] = [
            .switched(at: at, from: "acc-A", to: "acc-B", automatic: true), .failed(at: at), .conflict(at: at),
            .needsAttention(at: at), .noRoom(at: at), .waiting(at: at), .paused(at: at),
        ]
        for status in all { XCTAssertEqual(try roundTrip(status), status) }
        var state = ClaudeCodeState()
        state.links = ["acc-A": UUID()]
        state.status = .switched(at: at, from: "acc-A", to: "acc-B", automatic: false)
        state.noRoomNotified = ["acc-B"]
        XCTAssertEqual(try roundTrip(state), state)
    }

    func testTheLogKeepsTheNewest500() {
        var log: [ClaudeCodeSwitchLogEntry] = []
        for index in 0..<503 {
            log = ClaudeCodeSwitchLogEntry.appending(
                .init(at: Date(timeIntervalSince1970: Double(index)), from: "a", to: "b", automatic: false, rule: nil), to: log)
        }
        XCTAssertEqual(log.count, 500)
        XCTAssertEqual(log.first?.at, Date(timeIntervalSince1970: 3))
        XCTAssertEqual(log.last?.at, Date(timeIntervalSince1970: 502))
    }
}
