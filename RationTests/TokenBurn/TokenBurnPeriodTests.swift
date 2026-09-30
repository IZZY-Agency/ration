import XCTest
@testable import Ration

final class TokenBurnPeriodTests: XCTestCase {
    private func calendar(_ zone: String = "Europe/Paris") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ text: String, _ zone: String = "Europe/Paris") -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
        formatter.timeZone = TimeZone(identifier: zone)!
        return formatter.date(from: text)!
    }

    // MARK: Plan prices (spec §10, dated 2026-09-30)

    func testMonthlyPlanPrices() {
        XCTAssertEqual(ClaudePlanPrice.monthlyUSD(.claudePro), 20)
        XCTAssertEqual(ClaudePlanPrice.monthlyUSD(.claudeMax5x), 100)
        XCTAssertEqual(ClaudePlanPrice.monthlyUSD(.claudeMax20x), 200)
        XCTAssertNil(ClaudePlanPrice.monthlyUSD(.chatGPTPro20x), "Claude plans only")
        XCTAssertNil(ClaudePlanPrice.monthlyUSD(nil))
        XCTAssertEqual(ClaudePlanPrice.date, "2026-09-30")
    }

    // MARK: Periods (spec §5.4)

    func testTheCycleWhenTheRenewalDayIsKnown() {
        let period = TokenBurnPeriod.current(renewalDay: 15, now: date("2026-09-30T10:00:00"), calendar: calendar())
        XCTAssertEqual(period, TokenBurnPeriod(start: date("2026-09-15T00:00:00"), end: date("2026-10-15T00:00:00"), kind: .cycle))
    }

    func testTheCalendarMonthWhenItIsNot() {
        let period = TokenBurnPeriod.current(renewalDay: nil, now: date("2026-09-30T23:59:00"), calendar: calendar())
        XCTAssertEqual(period, TokenBurnPeriod(start: date("2026-09-01T00:00:00"), end: date("2026-10-01T00:00:00"), kind: .month))
    }

    /// A minute belongs to the period containing its start: [start, end).
    func testBoundariesAreHalfOpen() {
        let cal = calendar()
        let atRenewal = TokenBurnPeriod.current(renewalDay: 15, now: date("2026-10-15T00:00:00"), calendar: cal)
        XCTAssertEqual(atRenewal.start, date("2026-10-15T00:00:00"))
        let justBefore = TokenBurnPeriod.current(renewalDay: 15, now: date("2026-10-14T23:59:59"), calendar: cal)
        XCTAssertEqual(justBefore.end, date("2026-10-15T00:00:00"))
    }

    /// Renewal on the 31st: the month-length clamp, three cycles back.
    func testThePreviousThreeCyclesFollowTheClamp() {
        let cal = calendar()
        let current = TokenBurnPeriod.current(renewalDay: 31, now: date("2026-03-10T12:00:00"), calendar: cal)
        XCTAssertEqual(current.start, date("2026-02-28T00:00:00"))
        XCTAssertEqual(current.end, date("2026-03-31T00:00:00"))
        let previous = current.previous(count: 3, renewalDay: 31, calendar: cal)
        XCTAssertEqual(previous.map(\.start), [date("2026-01-31T00:00:00"), date("2025-12-31T00:00:00"), date("2025-11-30T00:00:00")])
        XCTAssertEqual(previous.map(\.end), [date("2026-02-28T00:00:00"), date("2026-01-31T00:00:00"), date("2025-12-31T00:00:00")])
        XCTAssertTrue(previous.allSatisfy { $0.kind == .cycle })
    }

    func testThePreviousMonths() {
        let current = TokenBurnPeriod.current(renewalDay: nil, now: date("2026-01-20T12:00:00"), calendar: calendar())
        let previous = current.previous(count: 2, renewalDay: nil, calendar: calendar())
        XCTAssertEqual(previous.map(\.start), [date("2025-12-01T00:00:00"), date("2025-11-01T00:00:00")])
        XCTAssertTrue(previous.allSatisfy { $0.kind == .month })
    }

    /// Boundaries are local midnights of the current time zone.
    func testATimeZoneChangeMovesTheBoundaries() {
        let now = date("2026-09-30T10:00:00")
        let paris = TokenBurnPeriod.current(renewalDay: 15, now: now, calendar: calendar("Europe/Paris"))
        let kyiv = TokenBurnPeriod.current(renewalDay: 15, now: now, calendar: calendar("Europe/Kyiv"))
        XCTAssertEqual(paris.start.timeIntervalSince(kyiv.start), 3_600)
    }

    // MARK: Value against the plan

    // MARK: The chosen period: the card shows dollars for a period chosen in Settings

    /// "Last 30 days" is today and the 29 local days before it.
    func testTheLast30DaysAreWholeLocalDaysEndingTonight() {
        let period = TokenBurnPeriod.current(choice: .last30Days, renewalDay: 15, now: date("2026-09-30T10:00:00"), calendar: calendar())
        XCTAssertEqual(period, TokenBurnPeriod(start: date("2026-09-01T00:00:00"), end: date("2026-10-01T00:00:00"), kind: .days(30)))
    }

    func testTheLast7DaysAndTheWeeksBefore() {
        let period = TokenBurnPeriod.current(choice: .last7Days, renewalDay: nil, now: date("2026-09-30T23:59:00"), calendar: calendar())
        XCTAssertEqual(period, TokenBurnPeriod(start: date("2026-09-24T00:00:00"), end: date("2026-10-01T00:00:00"), kind: .days(7)))
        XCTAssertEqual(period.previous(count: 2, choice: .last7Days, renewalDay: nil, calendar: calendar()), [
            TokenBurnPeriod(start: date("2026-09-17T00:00:00"), end: date("2026-09-24T00:00:00"), kind: .days(7)),
            TokenBurnPeriod(start: date("2026-09-10T00:00:00"), end: date("2026-09-17T00:00:00"), kind: .days(7)),
        ])
    }

    /// A daylight-saving change keeps whole local days (Paris, 2026-10-25).
    func testDaysAcrossADaylightSavingChange() {
        let period = TokenBurnPeriod.current(choice: .last7Days, renewalDay: nil, now: date("2026-10-27T12:00:00"), calendar: calendar())
        XCTAssertEqual(period.start, date("2026-10-21T00:00:00"))
        XCTAssertEqual(period.end, date("2026-10-28T00:00:00"))
    }

    func testThisMonthIgnoresTheRenewalDay() {
        let period = TokenBurnPeriod.current(choice: .thisMonth, renewalDay: 15, now: date("2026-09-30T10:00:00"), calendar: calendar())
        XCTAssertEqual(period.kind, .month)
        XCTAssertEqual(period.start, date("2026-09-01T00:00:00"))
    }

    func testTheBillingCycleFallsBackToTheMonth() {
        let now = date("2026-09-30T10:00:00")
        XCTAssertEqual(TokenBurnPeriod.current(choice: .billingCycle, renewalDay: 15, now: now, calendar: calendar()).kind, .cycle)
        XCTAssertEqual(TokenBurnPeriod.current(choice: .billingCycle, renewalDay: nil, now: now, calendar: calendar()).kind, .month)
    }

    /// The plan price is monthly: a week's value is not compared with it.
    func testNoRatioForAWeek() {
        let week = TokenBurnPeriod(start: date("2026-09-24T00:00:00"), end: date("2026-10-01T00:00:00"), kind: .days(7))
        let days30 = TokenBurnPeriod(start: date("2026-09-01T00:00:00"), end: date("2026-10-01T00:00:00"), kind: .days(30))
        var value = PlanValue()
        value.cents = 30_000
        XCTAssertNil(AccountPlanValue(period: week, value: value, planPriceUSD: 200).ratio)
        XCTAssertEqual(AccountPlanValue(period: days30, value: value, planPriceUSD: 200).ratio, Decimal(string: "1.5"))
    }

    func testTheChoiceIsKeptAndDefaultsTo30Days() throws {
        XCTAssertEqual(TokenBurnSettings().period, .last30Days)
        let old = try JSONDecoder().decode(TokenBurnSettings.self, from: Data(#"{"enabled":true}"#.utf8))
        XCTAssertEqual(old.period, .last30Days, "a file from before the choice")
        var settings = TokenBurnSettings()
        settings.period = .billingCycle
        let back = try JSONDecoder().decode(TokenBurnSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.period, .billingCycle)
    }

    func testTheRatioNeedsAKnownPlanPrice() {
        let period = TokenBurnPeriod.current(renewalDay: nil, now: date("2026-09-30T10:00:00"), calendar: calendar())
        var value = PlanValue()
        value.cents = 134_000
        let known = AccountPlanValue(period: period, value: value, planPriceUSD: 200)
        XCTAssertEqual(known.ratio, Decimal(string: "6.7"))
        XCTAssertNil(AccountPlanValue(period: period, value: value, planPriceUSD: nil).ratio)
        XCTAssertNil(AccountPlanValue(period: period, value: value, planPriceUSD: 0).ratio)
    }

    func testAtLeastIsCarried() {
        let period = TokenBurnPeriod.current(renewalDay: nil, now: date("2026-09-30T10:00:00"), calendar: calendar())
        var value = PlanValue()
        value.cents = 100
        value.unpricedTokens = 5
        XCTAssertTrue(AccountPlanValue(period: period, value: value, planPriceUSD: 20).isAtLeast)
        value.unpricedTokens = 0
        XCTAssertFalse(AccountPlanValue(period: period, value: value, planPriceUSD: 20).isAtLeast)
    }
}
