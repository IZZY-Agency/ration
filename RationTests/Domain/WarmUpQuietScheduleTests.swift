import XCTest
@testable import Ration

final class WarmUpQuietScheduleTests: XCTestCase {
    /// Always a FIXED zone — never the machine's, or these assertions would
    /// pass or fail depending on where the developer sits.
    private func calendar(_ tz: String = "Europe/Paris") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz)!
        return calendar
    }

    private func date(
        _ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0
    ) -> Date {
        cal.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    // MARK: Cells

    func testCellIndexMath() {
        XCTAssertEqual(WarmUpQuietSchedule.cellIndex(weekday: 1, hour: 0), 0)     // Sunday 00:00
        XCTAssertEqual(WarmUpQuietSchedule.cellIndex(weekday: 1, hour: 23), 23)
        XCTAssertEqual(WarmUpQuietSchedule.cellIndex(weekday: 2, hour: 0), 24)    // Monday 00:00
        XCTAssertEqual(WarmUpQuietSchedule.cellIndex(weekday: 7, hour: 23), 167)  // Saturday 23:00
    }

    func testEmptyScheduleIsNeverQuiet() {
        let cal = calendar()
        XCTAssertFalse(WarmUpQuietSchedule.allowAll.isQuiet(at: date(cal, 2026, 7, 15, 3), calendar: cal))
    }

    func testSelectedCellBlocksOnlyItsOwnWeekdayAndHour() {
        let cal = calendar()
        // 2026-07-15 is a Wednesday → weekday 4. Block 03:00.
        let schedule = WarmUpQuietSchedule(quietCells: [WarmUpQuietSchedule.cellIndex(weekday: 4, hour: 3)])
        XCTAssertEqual(cal.component(.weekday, from: date(cal, 2026, 7, 15)), 4)
        XCTAssertTrue(schedule.isQuiet(at: date(cal, 2026, 7, 15, 3, 59), calendar: cal))
        XCTAssertFalse(schedule.isQuiet(at: date(cal, 2026, 7, 15, 4), calendar: cal))  // next hour
        XCTAssertFalse(schedule.isQuiet(at: date(cal, 2026, 7, 16, 3), calendar: cal))  // next day
    }

    func testHourBoundaries() {
        let cal = calendar()
        let wednesday = 4
        let schedule = WarmUpQuietSchedule(quietCells: [
            WarmUpQuietSchedule.cellIndex(weekday: wednesday, hour: 0),
            WarmUpQuietSchedule.cellIndex(weekday: wednesday, hour: 23),
        ])
        XCTAssertTrue(schedule.isQuiet(at: date(cal, 2026, 7, 15, 0, 0), calendar: cal))
        XCTAssertTrue(schedule.isQuiet(at: date(cal, 2026, 7, 15, 23, 59), calendar: cal))
        XCTAssertFalse(schedule.isQuiet(at: date(cal, 2026, 7, 15, 1), calendar: cal))
    }

    // MARK: Holidays — half-open containment

    private func holiday(_ start: LocalDate, _ end: LocalDate) -> WarmUpQuietSchedule {
        WarmUpQuietSchedule(holidays: [HolidayRange(start: start, end: end, label: "Vacation")])
    }

    func testHolidayIncludesFirstAndLastDay() {
        let cal = calendar()
        let schedule = holiday(LocalDate(year: 2026, month: 8, day: 1), LocalDate(year: 2026, month: 8, day: 14))
        XCTAssertTrue(schedule.isQuiet(at: date(cal, 2026, 8, 1, 0, 0), calendar: cal))    // first midnight
        XCTAssertTrue(schedule.isQuiet(at: date(cal, 2026, 8, 14, 23, 59), calendar: cal)) // last minute
    }

    func testMidnightAfterLastDayIsNotQuiet() {
        let cal = calendar()
        let schedule = holiday(LocalDate(year: 2026, month: 8, day: 1), LocalDate(year: 2026, month: 8, day: 14))
        // Exactly 00:00 on the 15th — the half-open upper bound.
        XCTAssertFalse(schedule.isQuiet(at: date(cal, 2026, 8, 15, 0, 0), calendar: cal))
    }

    func testDayBeforeHolidayIsNotQuiet() {
        let cal = calendar()
        let schedule = holiday(LocalDate(year: 2026, month: 8, day: 1), LocalDate(year: 2026, month: 8, day: 14))
        XCTAssertFalse(schedule.isQuiet(at: date(cal, 2026, 7, 31, 23, 59), calendar: cal))
    }

    func testSingleDayHoliday() {
        let cal = calendar()
        let schedule = holiday(LocalDate(year: 2026, month: 8, day: 3), LocalDate(year: 2026, month: 8, day: 3))
        XCTAssertTrue(schedule.isQuiet(at: date(cal, 2026, 8, 3, 12), calendar: cal))
        XCTAssertFalse(schedule.isQuiet(at: date(cal, 2026, 8, 4, 0, 0), calendar: cal))
    }

    func testReversedRangeIsIgnoredNotTrapped() {
        let cal = calendar()
        let schedule = holiday(LocalDate(year: 2026, month: 8, day: 14), LocalDate(year: 2026, month: 8, day: 1))
        XCTAssertFalse(schedule.isQuiet(at: date(cal, 2026, 8, 5), calendar: cal))
    }

    func testHolidayCrossingMonthAndYearBoundaries() {
        let cal = calendar()
        let month = holiday(LocalDate(year: 2026, month: 7, day: 30), LocalDate(year: 2026, month: 8, day: 2))
        XCTAssertTrue(month.isQuiet(at: date(cal, 2026, 8, 1), calendar: cal))
        let year = holiday(LocalDate(year: 2026, month: 12, day: 30), LocalDate(year: 2027, month: 1, day: 2))
        XCTAssertTrue(year.isQuiet(at: date(cal, 2027, 1, 1), calendar: cal))
        XCTAssertFalse(year.isQuiet(at: date(cal, 2027, 1, 3), calendar: cal))
    }

    /// A holiday must stay on the same CIVIL days regardless of where the user
    /// is — the reason `LocalDate` exists rather than a stored `Date`.
    func testHolidayDoesNotShiftAcrossTimezones() {
        let schedule = holiday(LocalDate(year: 2026, month: 8, day: 1), LocalDate(year: 2026, month: 8, day: 1))
        for tz in ["Europe/Paris", "America/New_York", "Asia/Tokyo"] {
            let cal = calendar(tz)
            XCTAssertTrue(schedule.isQuiet(at: date(cal, 2026, 8, 1, 12), calendar: cal), "failed in \(tz)")
            XCTAssertFalse(schedule.isQuiet(at: date(cal, 2026, 8, 2, 12), calendar: cal), "failed in \(tz)")
        }
    }

    // MARK: DST

    /// Fall-back: Paris repeats 02:00–03:00 on the last Sunday of October.
    /// Both occurrences share weekday+hour, so both must be quiet. The
    /// transition instant is derived from the zone rather than hardcoded.
    func testFallBackRepeatedHourIsQuietForBothOccurrences() throws {
        let cal = calendar("Europe/Paris")
        let zone = cal.timeZone
        let october = date(cal, 2026, 10, 1)
        let transition = try XCTUnwrap(zone.nextDaylightSavingTimeTransition(after: october))
        // At the transition the clock jumps 03:00 CEST -> 02:00 CET, so 02:00
        // occurs at `transition - 1h` (CEST) and again at `transition` (CET).
        let firstOccurrence = transition.addingTimeInterval(-3600)
        let secondOccurrence = transition
        XCTAssertEqual(cal.component(.hour, from: firstOccurrence), 2)
        XCTAssertEqual(cal.component(.hour, from: secondOccurrence), 2)
        let weekday = cal.component(.weekday, from: secondOccurrence)
        let schedule = WarmUpQuietSchedule(quietCells: [
            WarmUpQuietSchedule.cellIndex(weekday: weekday, hour: 2)
        ])
        XCTAssertTrue(schedule.isQuiet(at: firstOccurrence, calendar: cal))
        XCTAssertTrue(schedule.isQuiet(at: secondOccurrence, calendar: cal))
    }

    /// Spring-forward day still resolves normally for hours that exist.
    /// 2026-03-29 is the spring-forward Sunday in Paris (02:00 -> 03:00).
    func testSpringForwardDayResolvesWithoutCrashing() {
        let cal = calendar("Europe/Paris")
        let sunday = cal.component(.weekday, from: date(cal, 2026, 3, 29, 12))
        XCTAssertEqual(sunday, 1)
        let schedule = WarmUpQuietSchedule(quietCells: [
            WarmUpQuietSchedule.cellIndex(weekday: sunday, hour: 4)
        ])
        XCTAssertTrue(schedule.isQuiet(at: date(cal, 2026, 3, 29, 4), calendar: cal))
        XCTAssertFalse(schedule.isQuiet(at: date(cal, 2026, 3, 29, 5), calendar: cal))
    }

    /// A holiday spanning the spring-forward day must not lose or gain a day —
    /// the reason containment adds one CALENDAR day rather than 86_400s.
    func testHolidaySpanningDSTTransition() {
        let cal = calendar("Europe/Paris")
        let schedule = holiday(LocalDate(year: 2026, month: 3, day: 28), LocalDate(year: 2026, month: 3, day: 29))
        XCTAssertTrue(schedule.isQuiet(at: date(cal, 2026, 3, 28, 12), calendar: cal))
        XCTAssertTrue(schedule.isQuiet(at: date(cal, 2026, 3, 29, 23, 59), calendar: cal))
        XCTAssertFalse(schedule.isQuiet(at: date(cal, 2026, 3, 30, 0, 0), calendar: cal))
    }

    func testHolidayAndCellCombine() {
        let cal = calendar()
        let schedule = WarmUpQuietSchedule(
            quietCells: [WarmUpQuietSchedule.cellIndex(weekday: 4, hour: 3)],
            holidays: [
                HolidayRange(
                    start: LocalDate(year: 2026, month: 8, day: 1),
                    end: LocalDate(year: 2026, month: 8, day: 2),
                    label: "X"
                )
            ]
        )
        XCTAssertTrue(schedule.isQuiet(at: date(cal, 2026, 7, 15, 3), calendar: cal))   // cell
        XCTAssertTrue(schedule.isQuiet(at: date(cal, 2026, 8, 1, 12), calendar: cal))   // holiday
        XCTAssertFalse(schedule.isQuiet(at: date(cal, 2026, 7, 15, 12), calendar: cal)) // neither
    }
}
