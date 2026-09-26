import XCTest
@testable import Ration

final class BillingCycleAnalyzerTests: XCTestCase {
    private func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
        utc().date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    /// One hourly bucket at the given wall-clock UTC hour.
    private func bucket(_ y: Int, _ m: Int, _ d: Int, _ h: Int,
                        consumed: Double, minRemaining: Double, tzOffsetSeconds: Int = 0) -> UsageHourlyBucket {
        UsageHourlyBucket(hourStart: at(y, m, d, h), tzOffsetSeconds: tzOffsetSeconds,
                          consumed: consumed, minRemaining: minRemaining, sampleCount: 1)
    }
    private func cycle(now: Date) -> BillingCycle {
        BillingCycle.current(renewalDay: 1, now: now, calendar: utc())
    }
    /// Constructs a `BillingCycle` with an explicit `now`/`end` relationship — used to
    /// pin the analyzer's own `min(now, end)` clamp for states `BillingCycle.current`
    /// never actually produces (it guarantees `now < end`).
    private func customCycle(start: Date, end: Date, now: Date) -> BillingCycle {
        BillingCycle(start: start, end: end, renewalDay: 1, now: now, calendar: utc())
    }

    func testCapacityUtilizationIsBurnPerObservedWindow() {
        // Cycle starts Jul 1; now Jul 3 00:00 → 48 elapsed hours (2 full days), well
        // above the weekly sufficiency floor of 42 observed hours (Change 1).
        // 48 observed hourly buckets, each consumed 0.05 → total 2.4 (weekly window 168h).
        // weeksObserved = 48/168; util = 2.4 / (48/168) = 2.4 * 168/48 = 8.4.
        let now = at(2026, 7, 3, 0)
        var buckets: [UsageHourlyBucket] = []
        for d in 1...2 { for h in 0..<24 { buckets.append(bucket(2026, 7, d, h, consumed: 0.05, minRemaining: 0.8)) } }
        let s = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.consumedAllowances, 2.4, accuracy: 1e-9)
        XCTAssertEqual(s.observedHours, 48)
        XCTAssertEqual(s.elapsedHours, 48)
        XCTAssertEqual(s.capacityUtilization, 8.4, accuracy: 1e-6)
        XCTAssertTrue(s.isSufficient)
    }

    func testResetUpwardJumpDoesNotInflateBurn() {
        // consumed is downward-only already; a bucket after a reset simply has
        // its own (small) consumed. Two days, each 6 buckets of 0.1 → 1.2 total.
        let now = at(2026, 7, 2, 6)
        let day1 = (0..<6).map { bucket(2026, 7, 1, $0, consumed: 0.1, minRemaining: 0.4) }
        let day2 = (0..<6).map { bucket(2026, 7, 2, $0, consumed: 0.1, minRemaining: 0.4) }
        let s = BillingCycleAnalyzer.summarize(buckets: day1 + day2, windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.consumedAllowances, 1.2, accuracy: 1e-9)
        XCTAssertEqual(s.daysUsed, 2)
    }

    func testSingleBurstDoesNotInflateHeadlineAcrossLaterDays() {
        // The v1 regression: a burst on day 1 then idle. Burn-based headline must
        // reflect only the actual burn, not a fill level lingering for days.
        let now = at(2026, 7, 4, 0) // 72 elapsed hours
        // Day 1: 24 buckets, one 0.5 burst, minRemaining 0.5 that hour.
        var buckets: [UsageHourlyBucket] = []
        for h in 0..<24 { buckets.append(bucket(2026, 7, 1, h, consumed: h == 10 ? 0.5 : 0, minRemaining: h >= 10 ? 0.5 : 1.0)) }
        // Days 2 & 3: observed but idle (remaining stays 0.5 = rolling window not yet reset), zero burn.
        for d in 2...3 { for h in 0..<24 { buckets.append(bucket(2026, 7, d, h, consumed: 0, minRemaining: 0.5)) } }
        let s = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.consumedAllowances, 0.5, accuracy: 1e-9) // burn total, not 3×
        XCTAssertEqual(s.daysUsed, 1)                              // only day 1 had burn
        // util = 0.5 / (72/168) = 0.5 * 168/72 ≈ 1.1667
        XCTAssertEqual(s.capacityUtilization, 0.5 * 168.0 / 72.0, accuracy: 1e-6)
    }

    func testInsufficientWhenCoverageBelowHalf() {
        // 72 elapsed hours, only 10 observed → coverage 0.14 → insufficient.
        let now = at(2026, 7, 4, 0)
        let buckets = (0..<10).map { bucket(2026, 7, 1, $0, consumed: 0.05, minRemaining: 0.9) }
        let s = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.coverageFraction, 10.0 / 72.0, accuracy: 1e-9)
        XCTAssertFalse(s.isSufficient)
    }

    func testInsufficientWhenFewerThanTwelveObservedHours() {
        // 11 elapsed hours, 11 observed → coverage 1.0 but observedHours < 12.
        let now = at(2026, 7, 1, 11)
        let buckets = (0..<11).map { bucket(2026, 7, 1, $0, consumed: 0.05, minRemaining: 0.9) }
        let s = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.observedHours, 11)
        XCTAssertFalse(s.isSufficient)
    }

    func testAllIdleObservedIsZeroButSufficient() {
        // 48 observed hours (2 full days), above the weekly 42h floor (Change 1).
        let now = at(2026, 7, 3, 0)
        var buckets: [UsageHourlyBucket] = []
        for d in 1...2 { for h in 0..<24 { buckets.append(bucket(2026, 7, d, h, consumed: 0, minRemaining: 1.0)) } }
        let s = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.capacityUtilization, 0, accuracy: 1e-12)
        XCTAssertEqual(s.daysUsed, 0)
        XCTAssertTrue(s.isSufficient)
    }

    func testEmptyBucketsIsNotSufficient() {
        let now = at(2026, 7, 1, 20)
        let s = BillingCycleAnalyzer.summarize(buckets: [], windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.observedHours, 0)
        XCTAssertFalse(s.isSufficient)
        XCTAssertEqual(s.capacityUtilization, 0)
    }

    func testAtCapDaysCountsDaysHittingNinetyFivePercent() {
        let now = at(2026, 7, 3, 0) // 48 elapsed hours
        var buckets: [UsageHourlyBucket] = []
        for h in 0..<24 { buckets.append(bucket(2026, 7, 1, h, consumed: 0.04, minRemaining: h == 12 ? 0.04 : 0.6)) } // day1 hits cap
        for h in 0..<24 { buckets.append(bucket(2026, 7, 2, h, consumed: 0.02, minRemaining: 0.6)) }                 // day2 no cap
        let s = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.atCapDays, 1)
        XCTAssertEqual(s.daysUsed, 2)
    }

    func testBucketsOutsideCycleAreExcluded() {
        let now = at(2026, 7, 1, 15)
        let inCycle = (0..<15).map { bucket(2026, 7, 1, $0, consumed: 0.02, minRemaining: 0.9) }
        let before = [bucket(2026, 6, 30, 23, consumed: 9.0, minRemaining: 0.0)] // previous cycle
        let s = BillingCycleAnalyzer.summarize(buckets: before + inCycle, windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.consumedAllowances, 15 * 0.02, accuracy: 1e-9) // 0.30, not 9.30
        XCTAssertEqual(s.observedHours, 15)
    }

    func testFiveHourWindowNormalizesByFiveHours() {
        let now = at(2026, 7, 1, 15)
        let buckets = (0..<15).map { bucket(2026, 7, 1, $0, consumed: 0.2, minRemaining: 0.5) }
        let s = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .fiveHour, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        // util = 3.0 / (15/5) = 3.0 / 3 = 1.0
        XCTAssertEqual(s.consumedAllowances, 3.0, accuracy: 1e-9)
        XCTAssertEqual(s.capacityUtilization, 1.0, accuracy: 1e-9)
    }

    // MARK: - Non-zero tz day-grouping

    func testNonZeroTimezoneOffsetGroupsBucketsByLocalDay() {
        // hourStart is a UTC instant; the day-grouping ordinal is
        // floor((hourStart + tzOffsetSeconds)/86400) — the LOCAL civil day, not the
        // raw UTC date. With tzOffsetSeconds = -8h (Pacific), a bucket captured at
        // 02:00 UTC on Jul 1 is locally still Jun 30 18:00 — a DIFFERENT civil day
        // than its raw UTC date. A regression that grouped by raw UTC day (ignoring
        // tzOffsetSeconds) would merge these two buckets into a single day.
        let now = at(2026, 7, 1, 23)
        let earlyLocal = bucket(2026, 7, 1, 2, consumed: 0.1, minRemaining: 0.9, tzOffsetSeconds: -8 * 3600)   // local Jun 30 18:00
        let lateLocal = bucket(2026, 7, 1, 10, consumed: 0.1, minRemaining: 0.02, tzOffsetSeconds: -8 * 3600) // local Jul 1 02:00, at cap
        let s = BillingCycleAnalyzer.summarize(buckets: [earlyLocal, lateLocal], windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.daysUsed, 2, "the two buckets fall on different LOCAL civil days")
        XCTAssertEqual(s.atCapDays, 1, "only the later-local-day bucket hit the cap")
    }

    // MARK: - Exact boundaries

    func testWeeklyExactlyAtGateObservedHoursIsSufficient() {
        // 42 observed hours = the weekly floor: max(12, ceil(0.25×168)) = 42.
        let now = at(2026, 7, 2, 18) // day1 (24h) + day2 0..<18 (18h) = 42 elapsed
        var buckets: [UsageHourlyBucket] = []
        for h in 0..<24 { buckets.append(bucket(2026, 7, 1, h, consumed: 0.01, minRemaining: 0.9)) }
        for h in 0..<18 { buckets.append(bucket(2026, 7, 2, h, consumed: 0.01, minRemaining: 0.9)) }
        let s = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.observedHours, 42)
        XCTAssertEqual(s.elapsedHours, 42)
        XCTAssertTrue(s.isSufficient)
    }

    func testWeeklyOneHourBelowGateIsInsufficient() {
        // 41 observed hours — one below the weekly floor of 42 — must be insufficient.
        let now = at(2026, 7, 2, 17)
        var buckets: [UsageHourlyBucket] = []
        for h in 0..<24 { buckets.append(bucket(2026, 7, 1, h, consumed: 0.01, minRemaining: 0.9)) }
        for h in 0..<17 { buckets.append(bucket(2026, 7, 2, h, consumed: 0.01, minRemaining: 0.9)) }
        let s = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.observedHours, 41)
        XCTAssertEqual(s.elapsedHours, 41)
        XCTAssertFalse(s.isSufficient)
    }

    func testFiveHourExactlyAtGateObservedHoursIsSufficient() {
        // 12 observed hours = the flat floor for the 5h window: max(12, ceil(0.25×5)) = 12.
        let now = at(2026, 7, 1, 12)
        let buckets = (0..<12).map { bucket(2026, 7, 1, $0, consumed: 0.01, minRemaining: 0.9) }
        let s = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .fiveHour, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.observedHours, 12)
        XCTAssertEqual(s.elapsedHours, 12)
        XCTAssertTrue(s.isSufficient)
    }

    func testFiveHourOneHourBelowGateIsInsufficient() {
        let now = at(2026, 7, 1, 11)
        let buckets = (0..<11).map { bucket(2026, 7, 1, $0, consumed: 0.01, minRemaining: 0.9) }
        let s = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .fiveHour, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.observedHours, 11)
        XCTAssertFalse(s.isSufficient)
    }

    func testCoverageExactlyOneHalfIsSufficient() {
        // 42 observed of 84 elapsed hours → coverage exactly 0.5, the last-insufficient/
        // first-sufficient coverage boundary (the check is `>=`, inclusive).
        let now = at(2026, 7, 4, 12) // cycle.start (Jul 1 00:00) + 84h
        var buckets: [UsageHourlyBucket] = []
        for h in 0..<24 { buckets.append(bucket(2026, 7, 1, h, consumed: 0.01, minRemaining: 0.9)) }
        for h in 0..<18 { buckets.append(bucket(2026, 7, 2, h, consumed: 0.01, minRemaining: 0.9)) }
        let s = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.observedHours, 42)
        XCTAssertEqual(s.elapsedHours, 84)
        XCTAssertEqual(s.coverageFraction, 0.5, accuracy: 1e-12)
        XCTAssertTrue(s.isSufficient)
    }

    func testCoverageJustBelowOneHalfIsInsufficient() {
        // Same 42 observed hours, one elapsed hour later (85) → coverage just under 0.5.
        let now = at(2026, 7, 4, 13)
        var buckets: [UsageHourlyBucket] = []
        for h in 0..<24 { buckets.append(bucket(2026, 7, 1, h, consumed: 0.01, minRemaining: 0.9)) }
        for h in 0..<18 { buckets.append(bucket(2026, 7, 2, h, consumed: 0.01, minRemaining: 0.9)) }
        let s = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.observedHours, 42)
        XCTAssertEqual(s.elapsedHours, 85)
        XCTAssertLessThan(s.coverageFraction, 0.5)
        XCTAssertFalse(s.isSufficient)
    }

    func testAtCapExactlyAtThresholdCounts() {
        // minRemaining exactly 0.05 (atCapRemaining) must count — the filter is `<=`.
        let now = at(2026, 7, 1, 5)
        let buckets = (0..<5).map { bucket(2026, 7, 1, $0, consumed: 0.01, minRemaining: $0 == 2 ? 0.05 : 0.9) }
        let s = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.atCapDays, 1)
    }

    func testIdleEpsilonBoundaryExcludesExactValueIncludesAbove() {
        // idleEpsilon filter is strict `>`: consumed exactly 1e-4 must NOT count as a
        // used day; a hair above must.
        let now = at(2026, 7, 3, 0)
        let exactlyAtEpsilon = bucket(2026, 7, 1, 0, consumed: 1e-4, minRemaining: 1.0)
        let justAboveEpsilon = bucket(2026, 7, 2, 0, consumed: 1e-4 + 1e-9, minRemaining: 1.0)
        let s = BillingCycleAnalyzer.summarize(buckets: [exactlyAtEpsilon, justAboveEpsilon], windowKind: .weekly, family: .rolling,
                                               cycle: cycle(now: now), calendar: utc())
        XCTAssertEqual(s.daysUsed, 1, "only the just-above-epsilon day counts as used")
    }

    // MARK: - min(now, end) end branch

    func testEndClampExcludesBucketsAtOrAfterCycleEnd() {
        // Production `BillingCycle.current` guarantees `now < end`; this pins the
        // analyzer's OWN `min(now, end)` clamp directly (via a hand-built `BillingCycle`)
        // so a min→max regression is caught even though this exact state can't arise
        // from `.current` today.
        let start = at(2026, 7, 1, 0)
        let end = at(2026, 7, 8, 0)
        let now = at(2026, 7, 10, 0) // now >= end
        let builtCycle = customCycle(start: start, end: end, now: now)
        let inWindow = bucket(2026, 7, 5, 0, consumed: 0.3, minRemaining: 0.5)     // inside [start, end)
        let afterEnd = bucket(2026, 7, 9, 0, consumed: 99.0, minRemaining: 0.0)    // at/after end — must be excluded
        let s = BillingCycleAnalyzer.summarize(buckets: [inWindow, afterEnd], windowKind: .weekly, family: .rolling,
                                               cycle: builtCycle, calendar: utc())
        XCTAssertEqual(s.consumedAllowances, 0.3, accuracy: 1e-9)
        XCTAssertEqual(s.observedHours, 1)
    }
}
