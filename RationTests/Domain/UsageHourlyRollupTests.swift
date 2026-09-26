import XCTest
@testable import Ration

final class UsageHourlyRollupTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private func sample(_ t: TimeInterval, _ r: Double) -> UsageHistorySample {
        UsageHistorySample(ts: Date(timeIntervalSince1970: t), remaining: r, resetsAt: nil)
    }

    func testConsumedAccumulatesDownwardDeltaWithinHour() {
        var buckets: [Date: UsageHourlyBucket] = [:]
        UsageHourlyRollup.fold(previous: nil, sample: sample(3600, 1.0), didReset: false, into: &buckets, timeZone: utc)
        UsageHourlyRollup.fold(previous: sample(3600, 1.0), sample: sample(3900, 0.8), didReset: false, into: &buckets, timeZone: utc)
        let bucket = buckets[Date(timeIntervalSince1970: 3600)]
        XCTAssertEqual(bucket?.consumed ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertEqual(bucket?.minRemaining ?? 1, 0.8, accuracy: 1e-9)
        XCTAssertEqual(bucket?.sampleCount, 2)
    }

    func testResetJumpIsNotCountedAsConsumption() {
        var buckets: [Date: UsageHourlyBucket] = [:]
        UsageHourlyRollup.fold(previous: sample(3900, 0.1), sample: sample(4000, 1.0), didReset: true, into: &buckets, timeZone: utc)
        XCTAssertEqual(buckets[Date(timeIntervalSince1970: 3600)]?.consumed ?? -1, 0, accuracy: 1e-9)
    }

    func testRollingResetsAtDriftAccumulatesNonzeroConsumed() {
        // End-to-end proof of the rolling-window reset-drift fix: a Claude
        // 5h sequence whose `resetsAt` drifts +1s every poll (rolling window)
        // while `remaining` decreases slightly must accumulate real burn in
        // the hourly bucket, not zero it out every poll.
        var series = UsageWindowSeries(kind: .fiveHour)
        let resetBase = Date(timeIntervalSince1970: 100_000)
        let readings: [(TimeInterval, Double)] = [(0, 0.72), (300, 0.70), (600, 0.68), (900, 0.66)]

        var buckets: [Date: UsageHourlyBucket] = [:]
        for (i, reading) in readings.enumerated() {
            let (ts, remaining) = reading
            let s = UsageHistorySample(
                ts: Date(timeIntervalSince1970: ts),
                remaining: remaining,
                resetsAt: resetBase.addingTimeInterval(TimeInterval(i))
            )
            let outcome = series.ingest(s, isClaudeFiveHour: true)
            guard case let .accepted(previous, didReset) = outcome else {
                XCTFail("expected accepted outcome for sample at ts=\(ts)")
                continue
            }
            if i > 0 { XCTAssertFalse(didReset, "poll \(i) must not be seen as a reset") }
            UsageHourlyRollup.fold(previous: previous, sample: s, didReset: didReset, into: &buckets, timeZone: utc)
        }

        XCTAssertEqual(series.samples.count, readings.count)
        let bucket = buckets[Date(timeIntervalSince1970: 0)]
        // Summed downward deltas: (0.72-0.70) + (0.70-0.68) + (0.68-0.66) = 0.06
        XCTAssertEqual(bucket?.consumed ?? 0, 0.06, accuracy: 1e-9)
        XCTAssertGreaterThan(bucket?.consumed ?? 0, 0, "Claude burn must accumulate, not stay zero")
    }

    func testRollingExpiryRecoveryMakesConsumedALowerBoundOnGrossUsage() {
        // Rolling-window property (the documented "observed lower bound" caveat, see
        // BillingCycleAnalyzer/BillingCycleView): when `remaining` RECOVERS between
        // two drops — old usage expiring out of the window while new usage lands —
        // that interval's real gross usage is masked entirely (`fold` clamps the
        // negative delta to 0). The folded `consumed` is therefore a LOWER BOUND on
        // true gross usage, never an exact figure.
        //
        // Readings (all within one clock hour): 0.7 → 0.5 (real drop, 0.2 gross, no
        // expiry) → 0.6 (net +0.1: 0.3 expired out of the window while 0.2 more gross
        // usage landed, netting to a RISE — the masked interval) → 0.4 (real drop,
        // 0.2 gross, no expiry).
        // True gross usage across the three intervals = 0.2 + 0.2 + 0.2 = 0.6.
        var buckets: [Date: UsageHourlyBucket] = [:]
        UsageHourlyRollup.fold(previous: nil, sample: sample(3600, 0.7), didReset: false, into: &buckets, timeZone: utc)
        UsageHourlyRollup.fold(previous: sample(3600, 0.7), sample: sample(3700, 0.5), didReset: false, into: &buckets, timeZone: utc)
        UsageHourlyRollup.fold(previous: sample(3700, 0.5), sample: sample(3800, 0.6), didReset: false, into: &buckets, timeZone: utc)
        UsageHourlyRollup.fold(previous: sample(3800, 0.6), sample: sample(3900, 0.4), didReset: false, into: &buckets, timeZone: utc)

        let consumed = buckets[Date(timeIntervalSince1970: 3600)]?.consumed ?? -1
        let trueGrossUsage = 0.6
        XCTAssertEqual(consumed, 0.4, accuracy: 1e-9) // 0.2 (drop) + 0 (masked recovery) + 0.2 (drop)
        XCTAssertLessThan(consumed, trueGrossUsage, "net fold must UNDERCOUNT gross usage across a rolling recovery")
    }

    func testHourStartAndOffsetUseCaptureZone() {
        let paris = TimeZone(identifier: "Europe/Paris")! // +01:00 in January
        var buckets: [Date: UsageHourlyBucket] = [:]
        let ts: TimeInterval = 1_704_069_000 // 2024-01-01 00:30:00 UTC = 01:30 Paris
        UsageHourlyRollup.fold(previous: nil, sample: sample(ts, 0.9), didReset: false, into: &buckets, timeZone: paris)
        let bucket = buckets.values.first
        XCTAssertEqual(bucket?.tzOffsetSeconds, 3600)
        // hourStart is the Paris 01:00 local hour expressed as a UTC instant (00:00 UTC).
        XCTAssertEqual(bucket?.hourStart, Date(timeIntervalSince1970: 1_704_067_200))
    }

    // MARK: v2 fields — observedSeconds / usedSeconds / resetCount (spec §3)

    private let gap: TimeInterval = 720

    private func fold(
        _ previous: UsageHistorySample?, _ s: UsageHistorySample, reset: Bool = false,
        gapLimit: TimeInterval? = nil, into buckets: inout [Date: UsageHourlyBucket], tz: TimeZone? = nil
    ) {
        UsageHourlyRollup.fold(
            previous: previous, sample: s, didReset: reset, gapLimit: gapLimit ?? gap,
            into: &buckets, timeZone: tz ?? utc
        )
    }

    private func hour(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    func testFirstSampleStartsV2FieldsAtZero() {
        var buckets: [Date: UsageHourlyBucket] = [:]
        fold(nil, sample(3600, 0.6), into: &buckets)
        let b = buckets[hour(3600)]
        XCTAssertEqual(b?.observedSeconds, 0, "no previous sample: nothing observed, but the field is v2 (non-nil)")
        XCTAssertEqual(b?.usedSeconds, 0)
        XCTAssertEqual(b?.resetCount, 0)
    }

    func testSteadyUseIntegratesUsedFractionOverObservedTime() {
        // Constant 40% used (remaining 0.6), polled every 300 s inside one hour.
        var buckets: [Date: UsageHourlyBucket] = [:]
        var prev: UsageHistorySample?
        for t in stride(from: 3600.0, through: 3600 + 900, by: 300) {
            let s = sample(t, 0.6)
            fold(prev, s, into: &buckets)
            prev = s
        }
        let b = buckets[hour(3600)]
        XCTAssertEqual(b?.observedSeconds ?? -1, 900, accuracy: 1e-9)
        XCTAssertEqual(b?.usedSeconds ?? -1, 0.4 * 900, accuracy: 1e-9)
        XCTAssertEqual((b?.usedSeconds ?? 0) / (b?.observedSeconds ?? 1), 0.4, accuracy: 1e-9)
    }

    func testTrapezoidRuleAveragesEndpoints() {
        // used 0.2 → 0.4 over 300 s: ∫ = 300 × (0.2 + 0.4) / 2 = 90.
        var buckets: [Date: UsageHourlyBucket] = [:]
        fold(nil, sample(3600, 0.8), into: &buckets)
        fold(sample(3600, 0.8), sample(3900, 0.6), into: &buckets)
        let b = buckets[hour(3600)]
        XCTAssertEqual(b?.observedSeconds ?? -1, 300, accuracy: 1e-9)
        XCTAssertEqual(b?.usedSeconds ?? -1, 90, accuracy: 1e-9)
    }

    func testIntervalSpanningHourBoundaryIsSplitProportionally() {
        // 6900 (used 0) → 7500 (used 0.6); boundary at 7200, used there = 0.3.
        var buckets: [Date: UsageHourlyBucket] = [:]
        fold(nil, sample(6900, 1.0), into: &buckets)
        fold(sample(6900, 1.0), sample(7500, 0.4), into: &buckets)
        let early = buckets[hour(3600)]
        let late = buckets[hour(7200)]
        XCTAssertEqual(early?.observedSeconds ?? -1, 300, accuracy: 1e-9)
        XCTAssertEqual(early?.usedSeconds ?? -1, 300 * (0 + 0.3) / 2, accuracy: 1e-9)
        XCTAssertEqual(late?.observedSeconds ?? -1, 300, accuracy: 1e-9)
        XCTAssertEqual(late?.usedSeconds ?? -1, 300 * (0.3 + 0.6) / 2, accuracy: 1e-9)
        // No double count: the two halves add up to the whole interval.
        let observed = (early?.observedSeconds ?? 0) + (late?.observedSeconds ?? 0)
        let used = (early?.usedSeconds ?? 0) + (late?.usedSeconds ?? 0)
        XCTAssertEqual(observed, 600, accuracy: 1e-9)
        XCTAssertEqual(used, 600 * 0.3, accuracy: 1e-9)
        // The legacy fields keep their semantics: the whole net drop lands in the sample's hour.
        XCTAssertEqual(early?.consumed ?? -1, 0, accuracy: 1e-9)
        XCTAssertEqual(late?.consumed ?? -1, 0.6, accuracy: 1e-9)
        XCTAssertEqual(early?.sampleCount, 1)
        XCTAssertEqual(late?.sampleCount, 1)
    }

    func testSplitFollowsCaptureZoneHoursInAHalfHourZone() {
        // Asia/Kolkata is +05:30: local hours start at :30 UTC. 1_800 s UTC = 05:30 local.
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        var buckets: [Date: UsageHourlyBucket] = [:]
        fold(nil, sample(1_500, 0.5), into: &buckets, tz: kolkata)
        fold(sample(1_500, 0.5), sample(2_100, 0.5), into: &buckets, tz: kolkata)
        XCTAssertEqual(buckets[hour(1_800 - 3600)]?.observedSeconds ?? -1, 300, accuracy: 1e-9)
        XCTAssertEqual(buckets[hour(1_800)]?.observedSeconds ?? -1, 300, accuracy: 1e-9)
        XCTAssertEqual(buckets[hour(1_800)]?.usedSeconds ?? -1, 150, accuracy: 1e-9)
    }

    func testGapLongerThanLimitIsCensored() {
        // A 3-hour sleep: neither observed nor used, in any hour it covers.
        var buckets: [Date: UsageHourlyBucket] = [:]
        fold(nil, sample(3600, 0.6), into: &buckets)
        fold(sample(3600, 0.6), sample(3600 + 3 * 3600, 0.5), into: &buckets)
        XCTAssertEqual(buckets[hour(3600)]?.observedSeconds, 0)
        XCTAssertEqual(buckets[hour(3600)]?.usedSeconds, 0)
        XCTAssertEqual(buckets[hour(4 * 3600)]?.observedSeconds, 0)
        XCTAssertEqual(buckets[hour(4 * 3600)]?.usedSeconds, 0)
        XCTAssertNil(buckets[hour(2 * 3600)], "slept hours get no bucket")
        XCTAssertNil(buckets[hour(3 * 3600)])
        // Legacy consumed is unchanged: the net drop still lands in the resume hour.
        XCTAssertEqual(buckets[hour(4 * 3600)]?.consumed ?? -1, 0.1, accuracy: 1e-9)
    }

    func testGapLimitIsInclusive() {
        var atLimit: [Date: UsageHourlyBucket] = [:]
        fold(nil, sample(3600, 0.6), into: &atLimit)
        fold(sample(3600, 0.6), sample(3600 + 720, 0.6), gapLimit: 720, into: &atLimit)
        XCTAssertEqual(atLimit[hour(3600)]?.observedSeconds ?? -1, 720, accuracy: 1e-9)

        var overLimit: [Date: UsageHourlyBucket] = [:]
        fold(nil, sample(3600, 0.6), into: &overLimit)
        fold(sample(3600, 0.6), sample(3600 + 721, 0.6), gapLimit: 720, into: &overLimit)
        XCTAssertEqual(overLimit[hour(3600)]?.observedSeconds, 0)
    }

    func testResetIntervalIsExcludedAndCounted() {
        var buckets: [Date: UsageHourlyBucket] = [:]
        fold(nil, sample(3600, 0.2), into: &buckets)
        fold(sample(3600, 0.2), sample(3900, 1.0), reset: true, into: &buckets)
        fold(sample(3900, 1.0), sample(4200, 0.9), into: &buckets)
        let b = buckets[hour(3600)]
        XCTAssertEqual(b?.observedSeconds ?? -1, 300, accuracy: 1e-9, "only the post-reset interval is observed")
        XCTAssertEqual(b?.usedSeconds ?? -1, 300 * (0 + 0.1) / 2, accuracy: 1e-9)
        XCTAssertEqual(b?.resetCount, 1)
    }

    func testResetCountLandsInTheResetSamplesHour() {
        var buckets: [Date: UsageHourlyBucket] = [:]
        fold(nil, sample(7000, 0.2), into: &buckets)
        fold(sample(7000, 0.2), sample(7300, 1.0), reset: true, into: &buckets)
        XCTAssertEqual(buckets[hour(3600)]?.resetCount, 0)
        XCTAssertEqual(buckets[hour(7200)]?.resetCount, 1)
        XCTAssertEqual(buckets[hour(3600)]?.observedSeconds, 0, "the reset interval is censored in both hours")
        XCTAssertEqual(buckets[hour(7200)]?.observedSeconds, 0)
    }

    func testFoldIntoLegacyBucketStartsV2FieldsAtThatSample() {
        // A bucket written before v2: no observed/used/reset fields.
        var buckets: [Date: UsageHourlyBucket] = [
            hour(3600): UsageHourlyBucket(
                hourStart: hour(3600), tzOffsetSeconds: 0, consumed: 0.1, minRemaining: 0.7, sampleCount: 4
            )
        ]
        XCTAssertNil(buckets[hour(3600)]?.observedSeconds)
        fold(sample(3900, 0.7), sample(4200, 0.5), reset: false, into: &buckets)
        let b = buckets[hour(3600)]
        XCTAssertEqual(b?.observedSeconds ?? -1, 300, accuracy: 1e-9)
        XCTAssertEqual(b?.usedSeconds ?? -1, 300 * (0.3 + 0.5) / 2, accuracy: 1e-9)
        XCTAssertEqual(b?.resetCount, 0)
        // Legacy semantics untouched.
        XCTAssertEqual(b?.consumed ?? -1, 0.3, accuracy: 1e-9)
        XCTAssertEqual(b?.minRemaining ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertEqual(b?.sampleCount, 5)
    }

    func testCensoredFoldIntoLegacyBucketStillStartsV2Fields() {
        var buckets: [Date: UsageHourlyBucket] = [
            hour(3600): UsageHourlyBucket(
                hourStart: hour(3600), tzOffsetSeconds: 0, consumed: 0, minRemaining: 0.7, sampleCount: 1
            )
        ]
        fold(sample(3600, 0.7), sample(4200, 1.0), reset: true, into: &buckets)
        XCTAssertEqual(buckets[hour(3600)]?.observedSeconds, 0)
        XCTAssertEqual(buckets[hour(3600)]?.usedSeconds, 0)
        XCTAssertEqual(buckets[hour(3600)]?.resetCount, 1)
    }

    func testSpanIntoHourWithoutBucketDoesNotCreateOne() {
        // The previous sample's hour is not in this dictionary (e.g. it lives in
        // last month's rollup segment). That part of the interval is dropped —
        // observed and used together — and no phantom bucket is created,
        // which would change legacy bucket counts and shadow the real bucket.
        var buckets: [Date: UsageHourlyBucket] = [:]
        fold(sample(6900, 0.5), sample(7500, 0.5), into: &buckets)
        XCTAssertNil(buckets[hour(3600)])
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[hour(7200)]?.observedSeconds ?? -1, 300, accuracy: 1e-9)
        XCTAssertEqual(buckets[hour(7200)]?.usedSeconds ?? -1, 150, accuracy: 1e-9)
    }

    func testDefaultGapLimitIsTwiceTheLongestNormalPoll() {
        XCTAssertEqual(
            PollSchedule.rollupGapLimit(lowPowerMode: false),
            2 * TimeInterval(PollSchedule.baseSeconds + PollSchedule.maxJitterSeconds)
        )
        XCTAssertEqual(
            PollSchedule.rollupGapLimit(lowPowerMode: true),
            2 * TimeInterval(PollSchedule.lowPowerSeconds + PollSchedule.maxJitterSeconds)
        )
        // The legacy fold signature (no gapLimit) uses the normal-cadence limit.
        var buckets: [Date: UsageHourlyBucket] = [:]
        UsageHourlyRollup.fold(previous: nil, sample: sample(3600, 0.6), didReset: false, into: &buckets, timeZone: utc)
        UsageHourlyRollup.fold(previous: sample(3600, 0.6), sample: sample(3600 + 720, 0.6), didReset: false, into: &buckets, timeZone: utc)
        UsageHourlyRollup.fold(previous: sample(4320, 0.6), sample: sample(4320 + 721, 0.6), didReset: false, into: &buckets, timeZone: utc)
        XCTAssertEqual(buckets[hour(3600)]?.observedSeconds ?? -1, 720, accuracy: 1e-9)
    }

    // MARK: Codable compatibility

    func testLegacyBucketJSONDecodesWithNilV2Fields() throws {
        let json = #"{"hourStart":3600,"tzOffsetSeconds":0,"consumed":0.25,"minRemaining":0.5,"sampleCount":3}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let b = try decoder.decode(UsageHourlyBucket.self, from: Data(json.utf8))
        XCTAssertEqual(b.consumed, 0.25)
        XCTAssertEqual(b.sampleCount, 3)
        XCTAssertNil(b.observedSeconds)
        XCTAssertNil(b.usedSeconds)
        XCTAssertNil(b.resetCount)
    }

    func testV2BucketRoundTripsAndLegacyBucketEncodesWithoutNewKeys() throws {
        var v2 = UsageHourlyBucket(hourStart: hour(3600), tzOffsetSeconds: 0, consumed: 0.1, minRemaining: 0.4, sampleCount: 2)
        v2.observedSeconds = 300
        v2.usedSeconds = 150
        v2.resetCount = 1
        let data = try JSONEncoder().encode(v2)
        XCTAssertEqual(try JSONDecoder().decode(UsageHourlyBucket.self, from: data), v2)

        let legacy = UsageHourlyBucket(hourStart: hour(3600), tzOffsetSeconds: 0, consumed: 0.1, minRemaining: 0.4, sampleCount: 2)
        let legacyJSON = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
        XCTAssertFalse(legacyJSON.contains("observedSeconds"))
        XCTAssertFalse(legacyJSON.contains("usedSeconds"))
        XCTAssertFalse(legacyJSON.contains("resetCount"))
    }

    // MARK: Fixed-window boundaries and split boundary hours

    private func stamped(_ t: TimeInterval, _ r: Double, resetsAt: TimeInterval?) -> UsageHistorySample {
        let reset: Date? = resetsAt.map { Date(timeIntervalSince1970: $0) }
        return UsageHistorySample(ts: Date(timeIntervalSince1970: t), remaining: r, resetsAt: reset)
    }

    private func foldWindow(
        _ previous: UsageHistorySample?, _ s: UsageHistorySample, reset: Bool = false, fixed: Bool,
        into buckets: inout [Date: UsageHourlyBucket]
    ) {
        UsageHourlyRollup.fold(
            previous: previous, sample: s, didReset: reset, isFixedWindow: fixed, gapLimit: gap,
            into: &buckets, timeZone: utc
        )
    }

    /// ChatGPT's reset time moved (a new window instance) while the meter
    /// fell from 0.5 to 0.4, so `detectReset` saw no reset. For a fixed
    /// window the move is a boundary: counted, the interval censored.
    func testFixedWindowMovedResetTimeIsABoundary() {
        var buckets: [Date: UsageHourlyBucket] = [:]
        let before = stamped(7200 - 300, 0.5, resetsAt: 7200)
        let after = stamped(7200 + 60, 0.4, resetsAt: 7200 + 7 * 86_400)
        foldWindow(nil, before, fixed: true, into: &buckets)
        foldWindow(before, after, fixed: true, into: &buckets)
        let resetHour = buckets[hour(7200)]
        XCTAssertEqual(resetHour?.resetCount, 1)
        XCTAssertEqual(resetHour?.observedSeconds, 0, "the interval crosses a reset: censored")
        XCTAssertEqual(buckets[hour(3600)]?.observedSeconds, 0)
        XCTAssertNil(resetHour?.preBoundaryMinRemaining, "the boundary is the hour's first sample")
        XCTAssertEqual(resetHour?.postBoundaryMinRemaining ?? -1, 0.4, accuracy: 1e-12)
        // Legacy consumed is unchanged: it follows `didReset` alone.
        XCTAssertEqual(resetHour?.consumed ?? -1, 0.1, accuracy: 1e-9)
    }

    /// Claude's rolling `resets_at` moves every poll: never a boundary.
    func testRollingWindowMovedResetTimeIsNotABoundary() {
        var buckets: [Date: UsageHourlyBucket] = [:]
        let before = stamped(3600, 0.5, resetsAt: 20_000)
        let after = stamped(3900, 0.4, resetsAt: 20_300)
        foldWindow(nil, before, fixed: false, into: &buckets)
        foldWindow(before, after, fixed: false, into: &buckets)
        XCTAssertEqual(buckets[hour(3600)]?.resetCount, 0)
        XCTAssertEqual(buckets[hour(3600)]?.observedSeconds ?? -1, 300, accuracy: 1e-9)
        XCTAssertNil(buckets[hour(3600)]?.postBoundaryMinRemaining)
    }

    /// A reset time that is unchanged, missing on either side, or moved by
    /// under a minute (rounding) is not a boundary.
    func testFixedWindowSameMissingOrJitteredResetTimeIsNotABoundary() {
        let cases: [(TimeInterval?, TimeInterval?)] = [(20_000, 20_000), (nil, 20_000), (20_000, nil), (20_000, 20_059)]
        for (old, new) in cases {
            var buckets: [Date: UsageHourlyBucket] = [:]
            let before = stamped(3600, 0.5, resetsAt: old)
            let after = stamped(3900, 0.4, resetsAt: new)
            foldWindow(nil, before, fixed: true, into: &buckets)
            foldWindow(before, after, fixed: true, into: &buckets)
            XCTAssertEqual(buckets[hour(3600)]?.resetCount, 0, "\(String(describing: old)) → \(String(describing: new))")
        }
        var moved: [Date: UsageHourlyBucket] = [:]
        let before = stamped(3600, 0.5, resetsAt: 20_000)
        let after = stamped(3900, 0.4, resetsAt: 20_061)
        foldWindow(nil, before, fixed: true, into: &moved)
        foldWindow(before, after, fixed: true, into: &moved)
        XCTAssertEqual(moved[hour(3600)]?.resetCount, 1, "moved by over a minute")
    }

    /// The instance ending in this hour reaches 100% (remaining 0) at
    /// 10:40, resets at 10:50, and the new one reads 0.95 by 10:55. The hour
    /// keeps both lows apart: 0 before the boundary, 0.95 after it.
    func testBoundaryHourKeepsThePreAndPostBoundaryLows() {
        var buckets: [Date: UsageHourlyBucket] = [:]
        let base: TimeInterval = 10 * 3600
        let readings: [(TimeInterval, Double, Bool)] = [
            (base + 600, 0.3, false), (base + 2400, 0.0, false), (base + 3000, 1.0, true), (base + 3300, 0.95, false),
        ]
        var previous: UsageHistorySample?
        for (t, r, reset) in readings {
            let s = sample(t, r)
            foldWindow(previous, s, reset: reset, fixed: false, into: &buckets)
            previous = s
        }
        let b = buckets[hour(base)]
        XCTAssertEqual(b?.resetCount, 1)
        XCTAssertEqual(b?.minRemaining ?? -1, 0, accuracy: 1e-12, "legacy low still mixes both")
        XCTAssertEqual(b?.preBoundaryMinRemaining ?? -1, 0, accuracy: 1e-12)
        XCTAssertEqual(b?.postBoundaryMinRemaining ?? -1, 0.95, accuracy: 1e-12)
    }

    /// Hours without a boundary carry neither split field.
    func testHourWithoutABoundaryHasNoSplitLows() {
        var buckets: [Date: UsageHourlyBucket] = [:]
        foldWindow(nil, sample(3600, 0.6), fixed: true, into: &buckets)
        foldWindow(sample(3600, 0.6), sample(3900, 0.5), fixed: true, into: &buckets)
        XCTAssertNil(buckets[hour(3600)]?.preBoundaryMinRemaining)
        XCTAssertNil(buckets[hour(3600)]?.postBoundaryMinRemaining)
    }
}
