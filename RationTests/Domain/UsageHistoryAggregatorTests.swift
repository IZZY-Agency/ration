import XCTest
@testable import Ration

final class UsageHistoryAggregatorTests: XCTestCase {
    private func bucket(hourStartUTC: TimeInterval, offset: Int, consumed: Double) -> UsageHourlyBucket {
        UsageHourlyBucket(hourStart: Date(timeIntervalSince1970: hourStartUTC), tzOffsetSeconds: offset, consumed: consumed, minRemaining: 0, sampleCount: 1)
    }

    func testHourOfDayUsesCaptureOffset() {
        // 09:00 and 10:00 local (offset +7200) on the same day.
        let nine = bucket(hourStartUTC: 9 * 3600 - 7200, offset: 7200, consumed: 0.2)
        let ten = bucket(hourStartUTC: 10 * 3600 - 7200, offset: 7200, consumed: 0.4)
        let heatmap = UsageHistoryAggregator.hourOfDayHeatmap([nine, ten])
        XCTAssertEqual(heatmap.first(where: { $0.hour == 9 })!.averageConsumed, 0.2, accuracy: 1e-9)
        XCTAssertEqual(heatmap.first(where: { $0.hour == 10 })!.averageConsumed, 0.4, accuracy: 1e-9)
    }

    func testDSTDuplicateLocalHourSumsIntoOneHourCell() {
        // Two distinct absolute hours that both map to local hour 1 (fall-back).
        let a = bucket(hourStartUTC: 1_000_000, offset: 7200, consumed: 0.1) // 1:00 CEST
        let b = bucket(hourStartUTC: 1_000_000 + 3600, offset: 3600, consumed: 0.3) // 1:00 CET
        // Arrange offsets so both compute local hour 1:
        let aa = bucket(hourStartUTC: 1 * 3600 - 7200, offset: 7200, consumed: 0.1)
        let bb = bucket(hourStartUTC: 1 * 3600 - 3600, offset: 3600, consumed: 0.3)
        let heatmap = UsageHistoryAggregator.hourOfDayHeatmap([aa, bb])
        XCTAssertEqual(heatmap.first(where: { $0.hour == 1 })!.averageConsumed, 0.2, accuracy: 1e-9) // avg of 0.1 & 0.3
        _ = (a, b)
    }

    func testDaySeriesSumsConsumedPerLocalDaySorted() {
        let day0h0 = bucket(hourStartUTC: 0 - 7200, offset: 7200, consumed: 0.1)
        let day0h1 = bucket(hourStartUTC: 3600 - 7200, offset: 7200, consumed: 0.2)
        let day1h0 = bucket(hourStartUTC: 86_400 - 7200, offset: 7200, consumed: 0.5)
        let series = UsageHistoryAggregator.daySeries([day1h0, day0h0, day0h1])
        let consumed = series.map { $0.consumed }
        XCTAssertEqual(consumed.count, 2)
        XCTAssertEqual(consumed[0], 0.3, accuracy: 1e-9)
        XCTAssertEqual(consumed[1], 0.5, accuracy: 1e-9)
        XCTAssertLessThan(series[0].dayStart, series[1].dayStart)
    }

    /// `daySeries` used to key by `localDayFloor - offset` (a
    /// UTC instant). Two buckets on the SAME capture-local civil day but with
    /// DIFFERENT `tzOffsetSeconds` (a DST transition day) produced two
    /// distinct keys, splitting one day's "Daily Burn" into two partial
    /// points. Keying by the offset-independent civil-day ordinal must merge
    /// them into one. RED before the fix: `series.count == 2`. GREEN after: 1.
    func testDSTTransitionDaySumsIntoOneDayBurn() {
        // Local 01:00 at offset +7200 (before a fall-back) and local 03:00 at
        // offset +3600 (after it) — both fall on capture-local civil day 0.
        let beforeFallback = bucket(hourStartUTC: 1 * 3600 - 7200, offset: 7200, consumed: 0.15)
        let afterFallback = bucket(hourStartUTC: 3 * 3600 - 3600, offset: 3600, consumed: 0.25)

        let series = UsageHistoryAggregator.daySeries([beforeFallback, afterFallback])

        XCTAssertEqual(series.count, 1, "same civil day must not split across a DST offset change")
        XCTAssertEqual(series.first?.consumed ?? 0, 0.4, accuracy: 1e-9)
    }
}
