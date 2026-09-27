import XCTest
@testable import Ration

final class UTCMonthTests: XCTestCase {
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testMonthContainingUsesUTCNotLocalTime() {
        // 23:30 local in Paris on 30 Sep is 21:30Z — still September.
        XCTAssertEqual(UTCMonth(containing: date("2026-09-30T21:30:00Z")).key, "2026-09")
        // 01:30 local in Paris on 1 Oct is 23:30Z on 30 Sep — still September in UTC.
        XCTAssertEqual(UTCMonth(containing: date("2026-09-30T23:30:00Z")).key, "2026-09")
        XCTAssertEqual(UTCMonth(containing: date("2026-10-01T00:00:00Z")).key, "2026-10")
    }

    func testStartAndNextStart() {
        let month = UTCMonth(containing: date("2028-02-15T12:00:00Z"))
        XCTAssertEqual(month.start, date("2028-02-01T00:00:00Z"))
        XCTAssertEqual(month.nextStart, date("2028-03-01T00:00:00Z"))
        XCTAssertEqual(UTCMonth(containing: date("2026-12-31T23:59:59Z")).nextStart, date("2027-01-01T00:00:00Z"))
    }

    func testDayHelpers() {
        XCTAssertEqual(UTCDay.start(of: date("2026-09-27T17:05:00Z")), date("2026-09-27T00:00:00Z"))
        XCTAssertEqual(UTCDay.nextStart(after: date("2026-09-27T17:05:00Z")), date("2026-09-28T00:00:00Z"))
    }

    func testOrdering() {
        XCTAssertLessThan(UTCMonth(year: 2026, month: 12), UTCMonth(year: 2027, month: 1))
    }
}
