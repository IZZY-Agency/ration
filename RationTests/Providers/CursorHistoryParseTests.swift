import XCTest
@testable import Ration

/// `CursorProviderAdapter.parseHistory`: the native gate on the history
/// script's payload. Anything off is `integrationChanged`, never a guess.
final class CursorHistoryParseTests: XCTestCase {
    private static func ms(_ iso: String) -> Int64 {
        Int64(ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000)
    }

    private let request = CursorHistoryRequest(
        months: [CursorInvoiceMonth(year: 2026, month: 11), CursorInvoiceMonth(year: 2026, month: 10)],
        currentPeriodStart: ISO8601DateFormatter().date(from: "2027-01-01T00:00:00Z")!
    )
    private let now = ISO8601DateFormatter().date(from: "2027-01-10T00:00:00Z")!

    private func body(_ cycles: [(String, String, Int)], exhausted: Bool = false, oldest: String = "null") -> String {
        var parts: [String] = []
        for (start, end, cents) in cycles {
            parts.append(#"{"periodStartMs":\#(Self.ms(start)),"periodEndMs":\#(Self.ms(end)),"spentCents":\#(cents)}"#)
        }
        return #"{"cycles":[\#(parts.joined(separator: ","))],"historyExhausted":\#(exhausted),"oldestEventMs":\#(oldest)}"#
    }

    func testDecodesClosedCyclesOldestFirst() async throws {
        let fetch = try await CursorProviderAdapter.parseHistory(
            body([("2026-12-01T00:00:00Z", "2027-01-01T00:00:00Z", 200), ("2026-11-01T00:00:00Z", "2026-12-01T00:00:00Z", 69)],
                 exhausted: true, oldest: String(Self.ms("2026-10-31T00:00:00Z"))),
            request: request, now: now
        )
        XCTAssertEqual(fetch.cycles.map(\.spentCents), [69, 200])
        XCTAssertTrue(fetch.cycles.allSatisfy(\.isClosed))
        XCTAssertTrue(fetch.historyExhausted)
        XCTAssertEqual(fetch.oldestEventAt, ISO8601DateFormatter().date(from: "2026-10-31T00:00:00Z"))
    }

    func testRejectsEveryImplausiblePayload() async {
        let cases: [(String, String)] = [
            ("not JSON", "<html>"),
            ("missing cycles", #"{"historyExhausted":true,"oldestEventMs":null}"#),
            ("negative total", body([("2026-12-01T00:00:00Z", "2027-01-01T00:00:00Z", -1)])),
            ("end before start", body([("2026-12-01T00:00:00Z", "2026-11-30T00:00:00Z", 1)])),
            ("month not asked for", body([("2026-09-01T00:00:00Z", "2026-10-01T00:00:00Z", 1)])),
            ("reaches into the open cycle", body([("2026-12-01T00:00:00Z", "2027-01-02T00:00:00Z", 1)])),
            ("overlap", body([("2026-12-01T00:00:00Z", "2027-01-01T00:00:00Z", 1), ("2026-11-01T00:00:00Z", "2026-12-02T00:00:00Z", 1)])),
            ("bad oldest event", body([], oldest: "-5")),
            ("end short of the month boundary", body([("2026-12-01T00:00:00Z", "2026-12-31T00:00:00Z", 1)])),
            ("start after the month's first instant", body([("2026-12-02T00:00:00Z", "2027-01-01T00:00:00Z", 1)])),
        ]
        for (name, payload) in cases {
            do {
                _ = try await CursorProviderAdapter.parseHistory(payload, request: request, now: now)
                XCTFail("\(name): expected integrationChanged")
            } catch let error as ProviderError {
                XCTAssertEqual(error, .integrationChanged, name)
            } catch {
                XCTFail("\(name): \(error)")
            }
        }
    }

    func testNotYetEndedCycleIsRejected() async {
        let early = ISO8601DateFormatter().date(from: "2026-12-20T00:00:00Z")!
        do {
            _ = try await CursorProviderAdapter.parseHistory(
                body([("2026-12-01T00:00:00Z", "2027-01-01T00:00:00Z", 1)]), request: request, now: early
            )
            XCTFail("expected integrationChanged")
        } catch {
            XCTAssertEqual(error as? ProviderError, .integrationChanged)
        }
    }
}
