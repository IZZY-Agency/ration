import XCTest
@testable import Ration

final class BillingCycleTests: XCTestCase {
    private func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, tz: String = "UTC") -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: tz)!
        return c.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    func testMidMonthRenewalPicksCurrentCycle() {
        let cycle = BillingCycle.current(renewalDay: 14, now: date(2026, 7, 21), calendar: utc())
        XCTAssertEqual(cycle.start, date(2026, 7, 14, 0))
        XCTAssertEqual(cycle.end, date(2026, 8, 14, 0))
        XCTAssertEqual(cycle.totalDays, 31)
        XCTAssertEqual(cycle.dayIndex, 8) // 14th is day 1 → 21st is day 8
    }

    func testBeforeRenewalDayPicksPreviousCycle() {
        let cycle = BillingCycle.current(renewalDay: 14, now: date(2026, 7, 3), calendar: utc())
        XCTAssertEqual(cycle.start, date(2026, 6, 14, 0))
        XCTAssertEqual(cycle.end, date(2026, 7, 14, 0))
    }

    func testNowExactlyOnRenewalMidnightStartsNewCycle() {
        let cycle = BillingCycle.current(renewalDay: 14, now: date(2026, 7, 14, 0), calendar: utc())
        XCTAssertEqual(cycle.start, date(2026, 7, 14, 0))
        XCTAssertEqual(cycle.dayIndex, 1)
    }

    func testRenewal31ClampsToFeb28AndSelectsNewCycleOnThatDay() {
        // 2026 Feb has 28 days; renewal 31 clamps to Feb 28.
        let onClampDay = BillingCycle.current(renewalDay: 31, now: date(2026, 2, 28, 6), calendar: utc())
        XCTAssertEqual(onClampDay.start, date(2026, 2, 28, 0)) // NOT Jan cycle
        XCTAssertEqual(onClampDay.end, date(2026, 3, 31, 0))
    }

    func testRenewal31ClampsToFeb29InLeapYear() {
        let cycle = BillingCycle.current(renewalDay: 31, now: date(2028, 2, 29, 6), calendar: utc())
        XCTAssertEqual(cycle.start, date(2028, 2, 29, 0))
        XCTAssertEqual(cycle.end, date(2028, 3, 31, 0))
    }

    func testCrossYearDecemberToJanuary() {
        let cycle = BillingCycle.current(renewalDay: 20, now: date(2026, 1, 5), calendar: utc())
        XCTAssertEqual(cycle.start, date(2025, 12, 20, 0))
        XCTAssertEqual(cycle.end, date(2026, 1, 20, 0))
    }

    func testForwardEndClampsToFebruaryLastDay() {
        // renewalDay 31 on Jan 31 → this cycle starts Jan 31; the FORWARD boundary
        // (next month) clamps to Feb's last day (28, non-leap 2026), not a literal
        // "Jan 31 + 1 month".
        let cycle = BillingCycle.current(renewalDay: 31, now: date(2026, 1, 31, 12), calendar: utc())
        XCTAssertEqual(cycle.start, date(2026, 1, 31, 0))
        XCTAssertEqual(cycle.end, date(2026, 2, 28, 0))
    }

    func testCrossYearEndRollsIntoJanuaryNextYear() {
        // renewalDay 20 on Dec 25 → this cycle starts Dec 20 of the same year; its
        // END (next renewal) rolls forward into January of the FOLLOWING year.
        let cycle = BillingCycle.current(renewalDay: 20, now: date(2026, 12, 25), calendar: utc())
        XCTAssertEqual(cycle.start, date(2026, 12, 20, 0))
        XCTAssertEqual(cycle.end, date(2027, 1, 20, 0))
    }

    func testDayIndexUsesCalendarDaysNotDurationAcrossDST() {
        // US spring-forward 2026-03-08 (23-hour day) in America/New_York.
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        let now = date(2026, 3, 10, 12, tz: "America/New_York")
        let cycle = BillingCycle.current(renewalDay: 1, now: now, calendar: c)
        XCTAssertEqual(cycle.start, date(2026, 3, 1, 0, tz: "America/New_York"))
        XCTAssertEqual(cycle.dayIndex, 10) // Mar 1 = day 1 → Mar 10 = day 10 despite the 23h day
    }
}
