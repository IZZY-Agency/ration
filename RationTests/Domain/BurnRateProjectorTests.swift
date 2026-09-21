import XCTest
@testable import Ration

final class BurnRateProjectorTests: XCTestCase {
    private func series(_ points: [(TimeInterval, Double)], resetsAt: Date?) -> UsageWindowSeries {
        var s = UsageWindowSeries(kind: .fiveHour)
        for (t, r) in points {
            _ = s.ingest(UsageHistorySample(ts: Date(timeIntervalSince1970: t), remaining: r, resetsAt: resetsAt), isClaudeFiveHour: true)
        }
        return s
    }
    private let interval: TimeInterval = 300

    func testSteadyBurnProjectsBeforeReset() {
        // 1.0 → 0.7 over 30 min ⇒ slope -0.01/min ⇒ exhaustion +70 min from last.
        let reset = Date(timeIntervalSince1970: 100_000)
        let s = series([(0, 1.0), (600, 0.9), (1200, 0.8), (1800, 0.7)], resetsAt: reset)
        let now = Date(timeIntervalSince1970: 1800 + 60)
        let eta = BurnRateProjector.projectedExhaustion(for: s, now: now, isAccountCurrent: true, refreshInterval: interval)
        XCTAssertNotNil(eta)
        XCTAssertEqual(eta!.timeIntervalSince1970, 1800 + 70 * 60, accuracy: 60)
    }

    func testInsufficientSamplesReturnsNil() {
        let s = series([(0, 1.0), (600, 0.9)], resetsAt: nil)
        XCTAssertNil(BurnRateProjector.projectedExhaustion(for: s, now: Date(timeIntervalSince1970: 660), isAccountCurrent: true, refreshInterval: interval))
    }

    func testFlatSeriesReturnsNil() {
        let s = series([(0, 0.5), (600, 0.5), (1200, 0.5)], resetsAt: nil)
        XCTAssertNil(BurnRateProjector.projectedExhaustion(for: s, now: Date(timeIntervalSince1970: 1260), isAccountCurrent: true, refreshInterval: interval))
    }

    func testStaleAccountReturnsNil() {
        let s = series([(0, 1.0), (600, 0.9), (1200, 0.8)], resetsAt: nil)
        XCTAssertNil(BurnRateProjector.projectedExhaustion(for: s, now: Date(timeIntervalSince1970: 1200), isAccountCurrent: false, refreshInterval: interval))
    }

    func testETAAfterResetReturnsNil() {
        let reset = Date(timeIntervalSince1970: 1300) // sooner than projected exhaustion
        let s = series([(0, 1.0), (600, 0.99), (1200, 0.98)], resetsAt: reset)
        XCTAssertNil(BurnRateProjector.projectedExhaustion(for: s, now: Date(timeIntervalSince1970: 1260), isAccountCurrent: true, refreshInterval: interval))
    }

    func testProjectionAccurateAtCurrentEpoch() {
        // Regression for catastrophic cancellation in leastSquares: squaring raw
        // ~1.78e9 epoch timestamps in n·sumXX − sumX² loses precision (~0.64%
        // slope error ⇒ ~36s ETA drift). Fit must be centered on a reference so
        // the analytic ETA is recovered to tight (sub-2s) accuracy.
        let base: TimeInterval = 1_780_000_000
        let points: [(TimeInterval, Double)] = [
            (base, 1.0),
            (base + 300, 0.95),
            (base + 600, 0.90),
            (base + 900, 0.85),
            (base + 1200, 0.80),
            (base + 1500, 0.75),
            (base + 1800, 0.70),
        ]
        let s = series(points, resetsAt: nil)
        let now = Date(timeIntervalSince1970: base + 1800 + 60)
        let eta = BurnRateProjector.projectedExhaustion(for: s, now: now, isAccountCurrent: true, refreshInterval: interval)
        XCTAssertNotNil(eta)
        // remaining 1.0 → 0.7 over 1800s (slope -1/6000/s) ⇒ exhaustion at last.ts + 70min.
        let expected = base + 1800 + 70 * 60
        XCTAssertEqual(eta!.timeIntervalSince1970, expected, accuracy: 2)
    }

    // MARK: Regression tests

    /// The ETA must be bounded by the series' authoritative
    /// `resetIdentity`, not only the latest sample's optional `resetsAt`. Only
    /// the FIRST sample here carries `resetsAt`; the identity it establishes
    /// persists even though the latest sample omits it. RED before the fix: the
    /// projector ignores the known identity and returns a (wildly wrong) ETA
    /// far past it. GREEN after: nil.
    func testETABoundedByResetIdentityEvenWhenLatestSampleOmitsResetsAt() {
        let identity = Date(timeIntervalSince1970: 1_300)
        var s = UsageWindowSeries(kind: .fiveHour)
        _ = s.ingest(UsageHistorySample(ts: Date(timeIntervalSince1970: 0), remaining: 1.0, resetsAt: identity), isClaudeFiveHour: true)
        _ = s.ingest(UsageHistorySample(ts: Date(timeIntervalSince1970: 600), remaining: 0.99, resetsAt: nil), isClaudeFiveHour: true)
        _ = s.ingest(UsageHistorySample(ts: Date(timeIntervalSince1970: 1_200), remaining: 0.98, resetsAt: nil), isClaudeFiveHour: true)
        XCTAssertEqual(s.resetIdentity, identity, "identity established by the first sample must persist")
        XCTAssertNil(s.samples.last?.resetsAt, "the latest sample must omit resetsAt for this scenario")

        let eta = BurnRateProjector.projectedExhaustion(
            for: s, now: Date(timeIntervalSince1970: 1_260), isAccountCurrent: true, refreshInterval: interval
        )
        XCTAssertNil(eta, "a known reset identity must bound the ETA even when the latest sample lacks resetsAt")
    }

    /// A clock rollback that makes the latest sample appear to be
    /// from the future (`now < last.ts`) must be rejected, not treated as
    /// "fresh". RED before the fix: the freshness check only bounds staleness
    /// from above, so a negative age slips through and a (bogus) ETA is
    /// returned. GREEN after: nil.
    func testFutureLastSampleFromClockRollbackReturnsNil() {
        let s = series([(0, 1.0), (600, 0.9), (1_200, 0.8)], resetsAt: nil)
        let now = Date(timeIntervalSince1970: 1_199) // one second BEFORE the last sample's ts
        let eta = BurnRateProjector.projectedExhaustion(for: s, now: now, isAccountCurrent: true, refreshInterval: interval)
        XCTAssertNil(eta)
    }

    /// A set that only meets the 10-minute minimum span BEFORE
    /// outlier trimming, but not after, must return nil — trimming the
    /// worst-residual point can shrink the remaining span below
    /// `minimumSpan`. Constructed via `restoredSamples` (not sequential
    /// `ingest`) so the first sample's large deviation doesn't itself trip
    /// the reset heuristics. The first sample (t=0) is the worst-residual
    /// point given points 200/400/650 are otherwise clustered relative to
    /// it, and it is not the last point, so it is the one trimmed; the
    /// remaining [200, 400, 650] span only 450s (< minimumSpan=600). RED
    /// before the fix: the projector fits the trimmed 3-point set anyway and
    /// returns a non-nil ETA. GREEN after: nil.
    func testSpanOnlyMetBeforeOutlierTrimReturnsNil() {
        let samples = [
            UsageHistorySample(ts: Date(timeIntervalSince1970: 0), remaining: 0.0, resetsAt: nil),
            UsageHistorySample(ts: Date(timeIntervalSince1970: 200), remaining: 1.0, resetsAt: nil),
            UsageHistorySample(ts: Date(timeIntervalSince1970: 400), remaining: 1.0, resetsAt: nil),
            UsageHistorySample(ts: Date(timeIntervalSince1970: 650), remaining: 0.1, resetsAt: nil),
        ]
        let s = UsageWindowSeries(kind: .fiveHour, restoredSamples: samples)
        // Sanity: the pre-trim set does span >= minimumSpan.
        XCTAssertGreaterThanOrEqual(
            samples.last!.ts.timeIntervalSince(samples.first!.ts), BurnRateProjector.minimumSpan
        )

        let eta = BurnRateProjector.projectedExhaustion(
            for: s, now: Date(timeIntervalSince1970: 680), isAccountCurrent: true, refreshInterval: interval
        )
        XCTAssertNil(eta)
    }
}
