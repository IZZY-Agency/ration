import XCTest
@testable import Ration

final class LocalDateTests: XCTestCase {
    private func calendar(_ tz: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz)!
        return calendar
    }

    func testCodableRoundTripAsISOString() throws {
        let date = LocalDate(year: 2026, month: 8, day: 1)
        let data = try JSONEncoder().encode(date)
        XCTAssertEqual(String(data: data, encoding: .utf8), "\"2026-08-01\"")
        XCTAssertEqual(try JSONDecoder().decode(LocalDate.self, from: data), date)
    }

    func testDecodeRejectsMalformedString() {
        let bad = "\"not-a-date\"".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(LocalDate.self, from: bad))
    }

    /// The parse is exact/anchored: a `split(separator:)`-based parser drops
    /// empty components, so it would accept "2026--01-01" and read
    /// "-001-01-01" as a positive year.
    func testDecodeRejectsNonCanonicalStrings() {
        for raw in [
            "2026--01-01",   // empty component
            "-001-01-01",    // negative/short year
            "2026-1-01",     // unpadded month
            "26-01-01",      // short year
            "2026-01-01-01", // too many components
            "2026-01",       // too few
            "2026-01-0a",    // non-numeric
            "2026-13-01",    // month out of range
            "2026-00-01",    // month zero
            "2026-01-32",    // day out of range
            "2026-02-30",    // date that does not exist
            "2026-04-31",    // date that does not exist
        ] {
            let data = "\"\(raw)\"".data(using: .utf8)!
            XCTAssertThrowsError(
                try JSONDecoder().decode(LocalDate.self, from: data),
                "should have rejected \(raw)"
            )
        }
    }

    func testDecodeAcceptsLeapDay() throws {
        let data = "\"2028-02-29\"".data(using: .utf8)!
        XCTAssertEqual(
            try JSONDecoder().decode(LocalDate.self, from: data),
            LocalDate(year: 2028, month: 2, day: 29)
        )
    }

    /// A `LocalDate` is a civil Gregorian date. Even when built with a
    /// non-Gregorian calendar it must produce Gregorian components (so it
    /// survives its own Gregorian decode) and round-trip — only the zone is
    /// borrowed.
    func testNonGregorianCalendarStillProducesGregorianComponents() throws {
        var hebrew = Calendar(identifier: .hebrew)
        hebrew.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        let instant = Date(timeIntervalSince1970: 1_784_000_000) // some 2026 instant
        let local = LocalDate(instant, calendar: hebrew)
        // Components are Gregorian (month within 1...12), so encoding+decoding
        // does not throw (which would reset the whole settings file on load).
        XCTAssertTrue((1...12).contains(local.month))
        let data = try JSONEncoder().encode(local)
        XCTAssertEqual(try JSONDecoder().decode(LocalDate.self, from: data), local)
        // And it matches the plain Gregorian reading of the same instant/zone.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "Asia/Jerusalem")!
        XCTAssertEqual(local, LocalDate(instant, calendar: gregorian))
    }

    func testComparable() {
        XCTAssertTrue(LocalDate(year: 2026, month: 1, day: 5) < LocalDate(year: 2026, month: 2, day: 1))
        XCTAssertTrue(LocalDate(year: 2025, month: 12, day: 31) < LocalDate(year: 2026, month: 1, day: 1))
        XCTAssertFalse(LocalDate(year: 2026, month: 3, day: 3) < LocalDate(year: 2026, month: 3, day: 3))
    }

    func testStartOfDayResolvesInGivenCalendar() throws {
        let paris = calendar("Europe/Paris")
        let start = try XCTUnwrap(LocalDate(year: 2026, month: 7, day: 15).startOfDay(in: paris))
        let components = paris.dateComponents([.year, .month, .day, .hour], from: start)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 15)
        XCTAssertEqual(components.hour, 0)
    }

    /// The whole point of the type: the same civil date in different zones is
    /// still that calendar day — it does not slide to the day before/after.
    func testSameCivilDateInDifferentZones() throws {
        let value = LocalDate(year: 2026, month: 7, day: 15)
        for tz in ["Europe/Paris", "America/New_York", "Asia/Tokyo"] {
            let cal = calendar(tz)
            let start = try XCTUnwrap(value.startOfDay(in: cal))
            XCTAssertEqual(cal.dateComponents([.day], from: start).day, 15, "failed in \(tz)")
            XCTAssertEqual(LocalDate(start, calendar: cal), value, "round-trip failed in \(tz)")
        }
    }

    func testInitFromDateUsesCalendarZone() {
        // 2026-07-15T23:30 in Paris is still July 15 there, and July 15 17:30 in NY.
        let paris = calendar("Europe/Paris")
        let instant = paris.date(from: DateComponents(year: 2026, month: 7, day: 15, hour: 23, minute: 30))!
        XCTAssertEqual(LocalDate(instant, calendar: paris), LocalDate(year: 2026, month: 7, day: 15))
        XCTAssertEqual(
            LocalDate(instant, calendar: calendar("America/New_York")),
            LocalDate(year: 2026, month: 7, day: 15)
        )
        // ...but in Tokyo that same instant is already July 16.
        XCTAssertEqual(
            LocalDate(instant, calendar: calendar("Asia/Tokyo")),
            LocalDate(year: 2026, month: 7, day: 16)
        )
    }
}
