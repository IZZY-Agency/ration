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
}
