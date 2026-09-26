import XCTest
@testable import Ration

/// Billing-cycle v2 metric (spec §2/§3/§6 "Analyzer"): rolling windows read
/// the time-weighted mean load from v2 observed/used seconds; fixed windows
/// read the mean of per-instance peaks. The family is passed in explicitly.
final class BillingCycleAnalyzerV2Tests: XCTestCase {
    private func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    /// Jul 1 2026 00:00 UTC: the cycle start (renewal day 1).
    private var cycleStart: Date { utc().date(from: DateComponents(year: 2026, month: 7, day: 1))! }
    private func hour(_ i: Int) -> Date { cycleStart.addingTimeInterval(Double(i) * 3600) }
    private func cycle(nowHour: Int) -> BillingCycle {
        BillingCycle.current(renewalDay: 1, now: hour(nowHour), calendar: utc())
    }

    /// A bucket `i` hours after the cycle start. v2 fields default to nil (legacy).
    private func b(_ i: Int, minRemaining: Double = 1, consumed: Double = 0,
                   observed: Double? = nil, used: Double? = nil, resetCount: Int? = nil) -> UsageHourlyBucket {
        UsageHourlyBucket(hourStart: hour(i), tzOffsetSeconds: 0, consumed: consumed,
                          minRemaining: minRemaining, sampleCount: 1,
                          observedSeconds: observed, usedSeconds: used, resetCount: resetCount)
    }
    /// A fully observed v2 rolling hour whose meter read `fraction` used throughout.
    private func load(_ i: Int, _ fraction: Double, consumed: Double = 0) -> UsageHourlyBucket {
        b(i, minRemaining: 1 - fraction, consumed: consumed, observed: 3600, used: fraction * 3600, resetCount: 0)
    }
    private func summarize(_ buckets: [UsageHourlyBucket], _ family: WindowFamily,
                           kind: UsageWindowKind = .weekly, nowHour: Int) -> CycleUtilizationSummary {
        BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: kind, family: family,
                                       cycle: cycle(nowHour: nowHour), calendar: utc())
    }

    // MARK: - Family

    func testFamilyComesFromTheProvider() {
        XCTAssertEqual(WindowFamily(provider: .claude), .rolling)
        XCTAssertEqual(WindowFamily(provider: .chatGPT), .fixed)
        XCTAssertNil(WindowFamily(provider: .cursor), "Cursor has no rolling/fixed usage windows")
    }

    /// The same buckets read differently per family: the analyzer never infers
    /// the family from the data.
    func testFamilyIsTakenFromTheCallerNotInferred() {
        let buckets = (0..<24).map { load($0, 0.2) } + (24..<48).map { load($0, 0.6) }
        let rolling = summarize(buckets, .rolling, nowHour: 48)
        let fixed = summarize(buckets, .fixed, nowHour: 48)
        XCTAssertEqual(rolling.family, .rolling)
        XCTAssertEqual(fixed.family, .fixed)
        XCTAssertEqual(rolling.capacityUtilization, 0.4, accuracy: 1e-12, "mean load")
        XCTAssertEqual(fixed.capacityUtilization, 0.6, accuracy: 1e-12, "one instance, peak 0.6")
    }

    // MARK: - Rolling

    /// Steady use on a rolling window: new usage replaces what ages out, so the
    /// net-drop burn is 0 while the meter sits at 40%. v2 reads 40%.
    func testRollingConstantFortyPercentMeterReadsFortyPercent() {
        let buckets = (0..<48).map { load($0, 0.4) }
        let s = summarize(buckets, .rolling, nowHour: 48)
        XCTAssertEqual(s.capacityUtilization, 0.4, accuracy: 1e-12)
        XCTAssertFalse(s.isLegacyLowerBound)
        XCTAssertEqual(s.consumedAllowances, 0, accuracy: 1e-12, "legacy burn stays the net drop")
        XCTAssertEqual(s.observedSeconds, 48 * 3600, accuracy: 1e-9)
        XCTAssertEqual(s.observedHours, 48)
        XCTAssertEqual(s.elapsedHours, 48)
        XCTAssertEqual(s.coverageFraction, 1, accuracy: 1e-12)
        XCTAssertTrue(s.isSufficient)
        XCTAssertEqual(s.daysUsed, 0, "daysUsed keeps its burn meaning")
        XCTAssertEqual(s.atCapDays, 0)
    }

    /// A burst of one full 5h allowance that ramps up and ages out: the mean
    /// load is Σ used / Σ observed, i.e. one allowance of 5 h over 48 h.
    func testRollingBurstThatAgesOutMatchesTheArithmetic() {
        let ramp = [0.1, 0.3, 0.5, 0.7, 0.9]
        var buckets = (0..<48).map { load($0, 0) }
        for (k, f) in ramp.enumerated() {
            buckets[24 + k] = load(24 + k, f, consumed: 0.2)
            buckets[33 - k] = load(33 - k, f)
        }
        let s = summarize(buckets, .rolling, kind: .fiveHour, nowHour: 48)
        XCTAssertEqual(s.capacityUtilization, 5.0 / 48.0, accuracy: 1e-12)
        XCTAssertFalse(s.isLegacyLowerBound)
    }

    /// A 12 h sleep leaves no buckets and a partially observed
    /// resume hour (whose legacy `consumed` holds the whole sleep's delta).
    /// Coverage drops; the result does not move.
    func testRollingSleepGapMovesCoverageNotTheResult() {
        let awake = (0..<60).map { load($0, 0.4) }
        let baseline = summarize(awake, .rolling, nowHour: 60)
        XCTAssertEqual(baseline.capacityUtilization, 0.4, accuracy: 1e-12)

        var slept = awake.filter { $0.hourStart < hour(20) || $0.hourStart > hour(32) }
        slept.append(b(32, minRemaining: 0.1, consumed: 0.9, observed: 600, used: 0.4 * 600, resetCount: 0))
        let s = summarize(slept, .rolling, nowHour: 60)
        XCTAssertEqual(s.capacityUtilization, 0.4, accuracy: 1e-12)
        XCTAssertFalse(s.isLegacyLowerBound)
        XCTAssertEqual(s.observedSeconds, 47 * 3600 + 600, accuracy: 1e-9)
        XCTAssertEqual(s.observedHours, 47, "watched hours come from observed seconds")
        XCTAssertEqual(s.coverageFraction, (47 * 3600 + 600) / (60 * 3600), accuracy: 1e-12)
        XCTAssertLessThan(s.coverageFraction, baseline.coverageFraction)
        XCTAssertTrue(s.isSufficient)
    }

    /// Legacy hours (no v2 seconds) in the same cycle are
    /// ignored by the rolling mean and by its coverage.
    func testRollingMixedLegacyAndV2UsesV2HoursOnly() {
        let legacy = (0..<30).map { b($0, minRemaining: 0.1, consumed: 0.2) }
        let v2 = (30..<78).map { load($0, 0.4) }
        let s = summarize(legacy + v2, .rolling, nowHour: 78)
        XCTAssertEqual(s.capacityUtilization, 0.4, accuracy: 1e-12)
        XCTAssertFalse(s.isLegacyLowerBound)
        XCTAssertEqual(s.observedSeconds, 48 * 3600, accuracy: 1e-9)
        XCTAssertEqual(s.observedHours, 48)
        XCTAssertEqual(s.elapsedHours, 78)
        XCTAssertEqual(s.coverageFraction, 48.0 / 78.0, accuracy: 1e-12)
        XCTAssertEqual(s.consumedAllowances, 6.0, accuracy: 1e-9, "legacy burn still spans every in-cycle bucket")
    }

    /// Too few v2 hours (10 h < the weekly 42 h floor): the card keeps the
    /// legacy lower-bound figure, framed as a lower bound.
    func testRollingInsufficientV2FallsBackToTheLegacyFigure() {
        let legacy = (0..<48).map { b($0, minRemaining: 0.8, consumed: 0.05) }
        let v2 = (48..<58).map { load($0, 0.2, consumed: 0.05) }
        let s = summarize(legacy + v2, .rolling, nowHour: 58)
        XCTAssertTrue(s.isLegacyLowerBound)
        XCTAssertEqual(s.family, .rolling)
        // Legacy: burn 2.9 over 58 bucket-hours of a 168 h window.
        XCTAssertEqual(s.consumedAllowances, 2.9, accuracy: 1e-9)
        XCTAssertEqual(s.capacityUtilization, 2.9 * 168.0 / 58.0, accuracy: 1e-9)
        XCTAssertEqual(s.observedHours, 58, "legacy coverage counts buckets")
        XCTAssertEqual(s.observedSeconds, 58 * 3600, accuracy: 1e-9)
        XCTAssertTrue(s.isSufficient)
    }

    /// Fix round F2: the v2/legacy switch is the absolute v2 observed time
    /// (≥ 42 h weekly), not coverage. 42 v2 hours at 0.42 coverage read v2,
    /// and a v2 figure is sufficient on its hours alone.
    func testRollingV2BelowHalfCoverageSwitchesOnceTheHoursAreReached() {
        let legacy = (0..<50).map { b($0, minRemaining: 0.8, consumed: 0.01) }
        let v2 = (50..<92).map { load($0, 0.3, consumed: 0.01) }
        let s = summarize(legacy + v2, .rolling, nowHour: 100)
        XCTAssertFalse(s.isLegacyLowerBound)
        XCTAssertEqual(s.capacityUtilization, 0.3, accuracy: 1e-12)
        XCTAssertEqual(s.coverageFraction, 0.42, accuracy: 1e-12, "coverage is still reported")
        XCTAssertTrue(s.isSufficient)
    }

    /// F2: a Mac on 8 h a day (coverage 1/3) gets v2 as soon as 42 v2 hours
    /// exist, and every later pass of the cycle stays v2 — including passes
    /// where coverage near 0.5 dips and no new data arrived.
    func testRollingOneWaySwitchNeverFlipsBackWithinTheCycle() {
        var buckets: [UsageHourlyBucket] = []
        for day in 0..<20 { for h in 0..<8 { buckets.append(load(day * 24 + 9 + h, 0.4, consumed: 0.02)) } }
        var sawV2 = false
        for nowHour in 1...(20 * 24) {
            let visible = buckets.filter { $0.hourStart < hour(nowHour) }
            let s = summarize(visible, .rolling, nowHour: nowHour)
            let v2Hours = visible.count
            if v2Hours >= 42 {
                XCTAssertFalse(s.isLegacyLowerBound, "now=\(nowHour)")
                XCTAssertTrue(s.isSufficient, "now=\(nowHour)")
                XCTAssertEqual(s.capacityUtilization, 0.4, accuracy: 1e-12)
                XCTAssertLessThan(s.coverageFraction, 0.5 + 1e-9)
                sawV2 = true
            } else {
                XCTAssertTrue(s.isLegacyLowerBound, "now=\(nowHour)")
                XCTAssertFalse(sawV2, "never back to legacy once v2 was shown")
            }
        }
        XCTAssertTrue(sawV2)
    }

    /// Exactly the floors (42 h and coverage 0.5) switch to v2; one second
    /// short stays legacy.
    func testRollingSwitchesToV2ExactlyAtTheSufficiencyFloor() {
        let legacy = (0..<42).map { b($0, minRemaining: 0.8, consumed: 0.01) }
        let v2 = (42..<84).map { load($0, 0.3) }
        let atFloor = summarize(legacy + v2, .rolling, nowHour: 84)
        XCTAssertFalse(atFloor.isLegacyLowerBound)
        XCTAssertEqual(atFloor.capacityUtilization, 0.3, accuracy: 1e-12)
        XCTAssertEqual(atFloor.coverageFraction, 0.5, accuracy: 1e-12)
        XCTAssertTrue(atFloor.isSufficient)

        var short = legacy + v2
        short[83] = b(83, minRemaining: 0.7, observed: 3599, used: 0.3 * 3599, resetCount: 0)
        let belowFloor = summarize(short, .rolling, nowHour: 84)
        XCTAssertTrue(belowFloor.isLegacyLowerBound)
    }

    func testRollingWithNoDataIsAnInsufficientLegacySummary() {
        let s = summarize([], .rolling, nowHour: 20)
        XCTAssertTrue(s.isLegacyLowerBound)
        XCTAssertFalse(s.isSufficient)
        XCTAssertEqual(s.capacityUtilization, 0)
    }

    /// v2 hours outside the cycle never feed the mean.
    func testRollingIgnoresV2HoursOutsideTheCycle() {
        var buckets = (0..<48).map { load($0, 0.4) }
        buckets.append(load(-1, 1.0))
        buckets.append(load(-30, 1.0))
        let s = summarize(buckets, .rolling, nowHour: 48)
        XCTAssertEqual(s.capacityUtilization, 0.4, accuracy: 1e-12)
        XCTAssertEqual(s.observedSeconds, 48 * 3600, accuracy: 1e-9)
    }

    // MARK: - Fixed

    /// Fixed-window instances of `length` hours from `startHour`, each ramping
    /// from full to its peak. `v2`: the reset hour carries `resetCount = 1` and
    /// its low-water mark is the previous instance's last reading (samples
    /// before the reset share the hour). Legacy: `resetCount` is nil and the
    /// reset lands on the hour, so `minRemaining` jumps.
    private func instances(_ peaks: [Double], length: Int = 168, startHour: Int = 0, v2: Bool) -> [UsageHourlyBucket] {
        var out: [UsageHourlyBucket] = []
        var previousLow: Double?
        for (k, peak) in peaks.enumerated() {
            for h in 0..<length {
                let i = startHour + k * length + h
                let remaining = 1 - peak * Double(h + 1) / Double(length)
                if v2 {
                    let isResetHour = h == 0 && previousLow != nil
                    let low = isResetHour ? min(previousLow ?? 1, remaining) : remaining
                    out.append(b(i, minRemaining: low, observed: 3600, used: 1800, resetCount: isResetHour ? 1 : 0))
                } else {
                    out.append(b(i, minRemaining: remaining))
                }
            }
            previousLow = 1 - peak
        }
        return out
    }

    func testFixedThreeWeeklyInstancesAverageTheirPeaks() {
        for v2 in [true, false] {
            let s = summarize(instances([0.9, 0.3, 0.6], v2: v2), .fixed, nowHour: 504)
            XCTAssertEqual(s.capacityUtilization, 0.6, accuracy: 1e-9, "v2=\(v2)")
            XCTAssertEqual(s.family, .fixed)
            XCTAssertFalse(s.isLegacyLowerBound, "fixed never falls back: peaks come from minRemaining")
            XCTAssertTrue(s.isSufficient)
        }
    }

    /// The instance in progress counts with its peak so far.
    func testFixedInProgressInstanceCountsWithItsPeakSoFar() {
        var buckets = instances([0.3, 0.6], v2: true)
        for h in 0..<40 {
            let remaining = 1 - 0.15 * Double(h + 1) / 40
            let low = h == 0 ? 0.4 : remaining
            buckets.append(b(336 + h, minRemaining: low, observed: 3600, used: 1800, resetCount: h == 0 ? 1 : 0))
        }
        let s = summarize(buckets, .fixed, nowHour: 376)
        XCTAssertEqual(s.capacityUtilization, (0.3 + 0.6 + 0.15) / 3, accuracy: 1e-9)
    }

    /// An instance that began before the cycle start counts; one that ended
    /// before it does not.
    func testFixedInstanceStraddlingTheCycleStartCounts() {
        var buckets: [UsageHourlyBucket] = []
        // Wholly pre-cycle instance, peak 0.95.
        for i in -100 ..< -72 { buckets.append(b(i, minRemaining: i == -73 ? 0.05 : 0.5)) }
        // Straddler: starts at -72, reaches 0.55 before the cycle and 0.5 by hour 47.
        for i in -72 ..< 0 { buckets.append(b(i, minRemaining: 0.55)) }
        for i in 0 ..< 48 { buckets.append(b(i, minRemaining: 0.5)) }
        // Next instance: resets at 48, peak so far 0.3.
        for i in 48 ..< 96 { buckets.append(b(i, minRemaining: i < 72 ? 0.98 : 0.7)) }
        let s = summarize(buckets, .fixed, nowHour: 96)
        XCTAssertEqual(s.capacityUtilization, (0.5 + 0.3) / 2, accuracy: 1e-9)
    }

    /// F4 + F3, v2: a mid-hour reset as Task 1 writes it. At 10:20 the sample
    /// jumps 0.90 → 1.00 (≥ 0.05, so `detectReset` fires and `resetCount` is
    /// 1), then the new instance uses 30% by 10:59. The hour's low (0.70) mixes
    /// both instances and shows no hour-level jump; the boundary comes from
    /// `resetCount` alone, and the hour feeds NEITHER instance — given to the
    /// old one it would inflate the old peak from 0.1 to 0.3.
    /// (A reset hidden in a gap with no upward jump at all is undetectable
    /// by either mechanism.)
    func testFixedMidHourResetIsFoundFromResetCountAndFeedsNeitherInstance() {
        var buckets: [UsageHourlyBucket] = []
        for i in 0..<10 { buckets.append(b(i, minRemaining: i < 9 ? 0.95 : 0.9, observed: 3600, used: 360, resetCount: 0)) }
        buckets.append(b(10, minRemaining: 0.7, observed: 3600, used: 540, resetCount: 1))
        for i in 11..<30 { buckets.append(b(i, minRemaining: i < 20 ? 0.65 : 0.5, observed: 3600, used: 1800, resetCount: 0)) }
        let s = summarize(buckets, .fixed, nowHour: 30)
        XCTAssertEqual(s.capacityUtilization, (0.1 + 0.5) / 2, accuracy: 1e-9)
    }

    /// F1, legacy: the reviewer's case. Old week peak 8% (low 0.92); reset at
    /// 10:20; the new week reaches 2% by 10:59 and 4% by 11:59. No hour ever
    /// jumps by 0.05 (hour 11 is +0.04), but hour 11's low (0.96) sits 0.06
    /// above what the previous low minus the hour's own `consumed` allows
    /// (0.92 − 0.02): something refilled. Hour 11 is the boundary.
    func testFixedLegacyMidHourResetIsFoundFromConsumedWithoutAJump() {
        var buckets: [UsageHourlyBucket] = []
        for i in 0..<10 { buckets.append(b(i, minRemaining: 1 - 0.008 * Double(i + 1), consumed: 0.008)) }
        // Hour 10: no more old use, reset at :20, new use 0.02 (consumed).
        buckets.append(b(10, minRemaining: 0.92, consumed: 0.02))
        buckets.append(b(11, minRemaining: 0.96, consumed: 0.02))
        for i in 12..<30 { buckets.append(b(i, minRemaining: 0.96 - 0.004 * Double(i - 11), consumed: 0.004)) }
        let s = summarize(buckets, .fixed, nowHour: 30)
        // Old 0.08; new instance: low 0.96 − 0.004 × 18 = 0.888 → peak 0.112.
        XCTAssertEqual(s.capacityUtilization, (0.08 + 0.112) / 2, accuracy: 1e-9)
    }

    /// F1 + F3, legacy: a mid-hour reset where the new instance ends the hour
    /// below the old low (0.85 < 0.90). The hour's low is 0.85 but the previous
    /// low minus `consumed` (0.90 − 0.15) predicts 0.75: the boundary is the
    /// reset hour itself, and its 0.85 feeds neither instance.
    func testFixedLegacyResetHourDetectedFromConsumedFeedsNeitherInstance() {
        var buckets: [UsageHourlyBucket] = []
        for i in 0..<10 { buckets.append(b(i, minRemaining: 1 - 0.01 * Double(i + 1), consumed: 0.01)) }
        buckets.append(b(10, minRemaining: 0.85, consumed: 0.15))
        for i in 11..<30 { buckets.append(b(i, minRemaining: i < 20 ? 0.8 : 0.6, consumed: i == 11 ? 0.05 : (i == 20 ? 0.2 : 0))) }
        let s = summarize(buckets, .fixed, nowHour: 30)
        XCTAssertEqual(s.capacityUtilization, (0.1 + 0.4) / 2, accuracy: 1e-9)
    }

    /// Both instances almost unused (old peak 2%, new 1% by the hour after):
    /// no signal reaches 0.05, so they merge. The documented blind spot.
    func testFixedLegacyNearlyIdleInstancesMerge() {
        var buckets: [UsageHourlyBucket] = []
        for i in 0..<10 { buckets.append(b(i, minRemaining: i < 5 ? 0.99 : 0.98, consumed: i == 0 || i == 5 ? 0.01 : 0)) }
        buckets.append(b(10, minRemaining: 0.98, consumed: 0.005))
        for i in 11..<30 { buckets.append(b(i, minRemaining: 0.99, consumed: i == 11 ? 0.005 : 0)) }
        let s = summarize(buckets, .fixed, nowHour: 30)
        XCTAssertEqual(s.capacityUtilization, 0.02, accuracy: 1e-9)
    }

    /// F3: an inferred boundary hour feeds neither instance, so a new instance
    /// whose only hour so far is its boundary hour has no peak yet.
    func testFixedBoundaryHourAloneIsNotAnInstanceYet() {
        var buckets = (0..<47).map { b($0, minRemaining: 0.5) }
        buckets.append(b(47, minRemaining: 0.9))
        let s = summarize(buckets, .fixed, nowHour: 48)
        XCTAssertEqual(s.capacityUtilization, 0.5, accuracy: 1e-9)
    }

    /// Legacy: the same gap with no `resetCount`; the upward
    /// jump in `minRemaining` across the gap marks the boundary.
    func testFixedResetInsideAGapIsFoundFromTheMinRemainingJump() {
        var buckets: [UsageHourlyBucket] = []
        for i in 0..<30 { buckets.append(b(i, minRemaining: i < 29 ? 0.8 : 0.6)) }
        for i in 40..<60 { buckets.append(b(i, minRemaining: i < 50 ? 0.97 : 0.8)) }
        let s = summarize(buckets, .fixed, nowHour: 60)
        XCTAssertEqual(s.capacityUtilization, (0.4 + 0.2) / 2, accuracy: 1e-9)
    }

    /// A known `resetCount == 0` is authoritative: an upward correction of
    /// `remaining` within one instance is not a reset.
    func testFixedKnownZeroResetCountIgnoresAnUpwardCorrection() {
        var buckets: [UsageHourlyBucket] = []
        for i in 0..<20 { buckets.append(b(i, minRemaining: 0.5, observed: 3600, used: 1800, resetCount: 0)) }
        for i in 20..<48 { buckets.append(b(i, minRemaining: 0.58, observed: 3600, used: 1800, resetCount: 0)) }
        let s = summarize(buckets, .fixed, nowHour: 48)
        XCTAssertEqual(s.capacityUtilization, 0.5, accuracy: 1e-9)
    }

    /// Upgrade hour (Task 1): v2 seconds present but `resetCount` nil means
    /// unknown, so the jump still marks the boundary.
    func testFixedNilResetCountWithV2SecondsStillInfersFromTheJump() {
        var buckets: [UsageHourlyBucket] = []
        for i in 0..<20 { buckets.append(b(i, minRemaining: 0.5)) }
        buckets.append(b(20, minRemaining: 0.9, observed: 1200, used: 100, resetCount: nil))
        for i in 21..<48 { buckets.append(b(i, minRemaining: 0.7, observed: 3600, used: 1800, resetCount: 0)) }
        let s = summarize(buckets, .fixed, nowHour: 48)
        XCTAssertEqual(s.capacityUtilization, (0.5 + 0.3) / 2, accuracy: 1e-9)
    }

    /// The jump threshold is `UsageWindowSeries.upwardJumpEpsilon`, inclusive.
    func testFixedJumpThresholdIsTheSeriesEpsilonInclusive() {
        func peaks(jumpTo value: Double) -> Double {
            var buckets: [UsageHourlyBucket] = []
            for i in 0..<24 { buckets.append(b(i, minRemaining: 0.55)) }
            for i in 24..<48 { buckets.append(b(i, minRemaining: value)) }
            return summarize(buckets, .fixed, nowHour: 48).capacityUtilization
        }
        XCTAssertEqual(UsageWindowSeries.upwardJumpEpsilon, 0.05)
        XCTAssertEqual(peaks(jumpTo: 0.60), (0.45 + 0.40) / 2, accuracy: 1e-9, "a 0.05 jump is a reset")
        XCTAssertEqual(peaks(jumpTo: 0.59), 0.45, accuracy: 1e-9, "a 0.04 jump is not")
    }

    /// Fixed coverage counts bucket-hours, because every bucket (legacy or
    /// v2) carries the `minRemaining` the peaks are read from. Sparse v2 hours
    /// (one sample each, few observed seconds) still count as watched hours.
    func testFixedCoverageCountsBucketHoursNotObservedSeconds() {
        let legacy = (0..<48).map { b($0, minRemaining: 0.7) }
        let legacySummary = summarize(legacy, .fixed, nowHour: 48)
        XCTAssertEqual(legacySummary.observedHours, 48)
        XCTAssertEqual(legacySummary.watchedSeconds, 48 * 3600, accuracy: 1e-9, "legacy hours count as full hours")
        XCTAssertEqual(legacySummary.observedSeconds, 48 * 3600, accuracy: 1e-9)
        XCTAssertTrue(legacySummary.isSufficient)

        let sparse = (0..<48).map { b($0, minRemaining: 0.7, observed: 600, used: 180, resetCount: 0) }
        let sparseSummary = summarize(sparse, .fixed, nowHour: 48)
        // "Watched" is the measured time (48 × 10 min = 8 h), while
        // sufficiency and coverage still count the 48 bucket-hours.
        XCTAssertEqual(sparseSummary.observedHours, 8)
        XCTAssertEqual(sparseSummary.watchedSeconds, 8 * 3600, accuracy: 1e-9)
        XCTAssertEqual(sparseSummary.observedSeconds, 48 * 3600, accuracy: 1e-9)
        XCTAssertEqual(sparseSummary.coverageFraction, 1, accuracy: 1e-12)
        XCTAssertTrue(sparseSummary.isSufficient)
        XCTAssertEqual(sparseSummary.capacityUtilization, 0.3, accuracy: 1e-9)
    }

    /// 48 hours with 10 measured minutes each read "watched 8"
    /// on the card, and the figure is still sufficient (48 bucket-hours).
    func testFixedWatchedShowsMeasuredTimeOnTheCard() {
        let sparse = (0..<48).map { b($0, minRemaining: 0.7, observed: 600, used: 180, resetCount: 0) }
        let s = summarize(sparse, .fixed, nowHour: 48)
        XCTAssertTrue(s.isSufficient)
        XCTAssertEqual(BillingCycleCopy.watchedHours(s), 8)
        XCTAssertTrue(BillingCycleCopy.detail(s, locale: L10n.en).hasSuffix("watched 8/48 hrs"))
        // A mix: legacy hours count 3600 each, v2 hours their measured seconds.
        var mixed = (0..<24).map { b($0, minRemaining: 0.7) }
        mixed += (24..<48).map { b($0, minRemaining: 0.7, observed: 1800, used: 540, resetCount: 0) }
        XCTAssertEqual(summarize(mixed, .fixed, nowHour: 48).watchedSeconds, 36 * 3600, accuracy: 1e-9)
    }

    /// A split boundary hour gives its pre-boundary low to the
    /// ending instance and its post-boundary low to the new one. The old
    /// instance reaches 100% only in its reset hour; its peak is 100%.
    func testFixedSplitBoundaryHourKeepsBothInstancesPeaks() {
        var buckets = (0..<10).map { b($0, minRemaining: 0.4, observed: 3600, used: 1800, resetCount: 0) }
        var resetHour = b(10, minRemaining: 0, observed: 3000, used: 2000, resetCount: 1)
        resetHour.preBoundaryMinRemaining = 0
        resetHour.postBoundaryMinRemaining = 0.95
        buckets.append(resetHour)
        buckets += (11..<20).map { b($0, minRemaining: 0.8, observed: 3600, used: 600, resetCount: 0) }
        let s = summarize(buckets, .fixed, kind: .fiveHour, nowHour: 20)
        XCTAssertEqual(s.capacityUtilization, (1.0 + 0.2) / 2, accuracy: 1e-9)
    }

    /// At the analyzer: the boundary sample opened the hour (no
    /// pre part), so the ending instance closes on its earlier hours (peak
    /// 50%) and the new one starts at the post low (peak 60%): 55%, not 60%.
    func testFixedSplitBoundaryWithoutAPrePartClosesOnTheEarlierHours() {
        var buckets = (0..<10).map { b($0, minRemaining: 0.5, observed: 3600, used: 1800, resetCount: 0) }
        var resetHour = b(10, minRemaining: 0.4, observed: 3300, used: 1980, resetCount: 1)
        resetHour.postBoundaryMinRemaining = 0.4
        buckets.append(resetHour)
        buckets += (11..<20).map { b($0, minRemaining: 0.4, observed: 3600, used: 2160, resetCount: 0) }
        let s = summarize(buckets, .fixed, nowHour: 20)
        XCTAssertEqual(s.capacityUtilization, 0.55, accuracy: 1e-9)
    }

    /// A boundary hour without the split (written before it existed) keeps
    /// the documented legacy rule: it feeds neither instance.
    func testFixedBoundaryHourWithoutTheSplitFeedsNeitherInstance() {
        var buckets = (0..<10).map { b($0, minRemaining: 0.4, observed: 3600, used: 1800, resetCount: 0) }
        buckets.append(b(10, minRemaining: 0, observed: 3000, used: 2000, resetCount: 1))
        buckets += (11..<20).map { b($0, minRemaining: 0.8, observed: 3600, used: 600, resetCount: 0) }
        let s = summarize(buckets, .fixed, kind: .fiveHour, nowHour: 20)
        XCTAssertEqual(s.capacityUtilization, (0.6 + 0.2) / 2, accuracy: 1e-9)
    }

    func testFixedWithNoDataIsInsufficientAndZero() {
        let s = summarize([], .fixed, nowHour: 20)
        XCTAssertEqual(s.capacityUtilization, 0)
        XCTAssertFalse(s.isSufficient)
        XCTAssertFalse(s.isLegacyLowerBound)
    }

    func testFixedKeepsDaysUsedAndAtCapDays() {
        var buckets = (0..<24).map { b($0, minRemaining: $0 == 12 ? 0.04 : 0.6, consumed: 0.04) }
        buckets += (24..<48).map { b($0, minRemaining: 0.6) }
        let s = summarize(buckets, .fixed, nowHour: 48)
        XCTAssertEqual(s.daysUsed, 1)
        XCTAssertEqual(s.atCapDays, 1)
    }

    // MARK: - Isolation

    /// The analyzer is nonisolated over Sendable inputs: it runs from a
    /// detached task and returns what the synchronous call returns.
    func testSummarizeRunsOffTheMainActorWithTheSameResult() async {
        let buckets = (0..<48).map { load($0, 0.4) }
        let c = cycle(nowHour: 48)
        let cal = utc()
        let sync = BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .weekly, family: .rolling,
                                                  cycle: c, calendar: cal)
        let detached = await Task.detached {
            XCTAssertFalse(Thread.isMainThread)
            return BillingCycleAnalyzer.summarize(buckets: buckets, windowKind: .weekly, family: .rolling,
                                                  cycle: c, calendar: cal)
        }.value
        XCTAssertEqual(detached, sync)
    }
}
