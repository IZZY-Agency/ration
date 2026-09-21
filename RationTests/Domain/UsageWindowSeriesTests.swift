import XCTest
@testable import Ration

final class UsageWindowSeriesTests: XCTestCase {
    private func sample(_ t: TimeInterval, _ remaining: Double, resetsAt: Date? = nil) -> UsageHistorySample {
        UsageHistorySample(ts: Date(timeIntervalSince1970: t), remaining: remaining, resetsAt: resetsAt)
    }

    func testStableFutureResetIgnoresUpwardCorrection() {
        let reset = Date(timeIntervalSince1970: 100_000)
        var series = UsageWindowSeries(kind: .fiveHour)
        _ = series.ingest(sample(1000, 0.50, resetsAt: reset), isClaudeFiveHour: true)
        let outcome = series.ingest(sample(1300, 0.55, resetsAt: reset), isClaudeFiveHour: true)
        XCTAssertEqual(outcome, .accepted(previous: sample(1000, 0.50, resetsAt: reset), didReset: false))
        XCTAssertEqual(series.samples.count, 2)
    }

    func testChangedResetsAtSegmentsOnce() {
        var series = UsageWindowSeries(kind: .fiveHour)
        _ = series.ingest(sample(1000, 0.20, resetsAt: Date(timeIntervalSince1970: 5000)), isClaudeFiveHour: true)
        let outcome = series.ingest(sample(6000, 1.0, resetsAt: Date(timeIntervalSince1970: 24000)), isClaudeFiveHour: true)
        XCTAssertEqual(outcome, .accepted(previous: sample(1000, 0.20, resetsAt: Date(timeIntervalSince1970: 5000)), didReset: true))
        XCTAssertEqual(series.samples, [sample(6000, 1.0, resetsAt: Date(timeIntervalSince1970: 24000))])
    }

    func testStalePastResetsAtDoesNotReclearEverySample() {
        let stale = Date(timeIntervalSince1970: 1000) // already in the past vs sample ts
        var series = UsageWindowSeries(kind: .fiveHour)
        _ = series.ingest(sample(5000, 0.40, resetsAt: stale), isClaudeFiveHour: true)
        _ = series.ingest(sample(5300, 0.38, resetsAt: stale), isClaudeFiveHour: true)
        XCTAssertEqual(series.samples.count, 2) // NOT reset back to 1 each time
    }

    func testAbsentMetadataUpwardJumpSegmentsAtEpsilon() {
        var series = UsageWindowSeries(kind: .fiveHour)
        _ = series.ingest(sample(1000, 0.30), isClaudeFiveHour: true)
        let outcome = series.ingest(sample(1300, 0.35), isClaudeFiveHour: true) // +0.05 == ε
        XCTAssertEqual(outcome, .accepted(previous: sample(1000, 0.30), didReset: true))
    }

    func testWeeklyNotStartedDoesNotFireButClaudeFiveHourDoes() {
        var weekly = UsageWindowSeries(kind: .weekly)
        _ = weekly.ingest(sample(1000, 0.985), isClaudeFiveHour: false)
        let weeklyOutcome = weekly.ingest(sample(1900, 0.990), isClaudeFiveHour: false) // +0.005, not Claude-5h
        XCTAssertEqual(weeklyOutcome, .accepted(previous: sample(1000, 0.985), didReset: false))

        var five = UsageWindowSeries(kind: .fiveHour)
        _ = five.ingest(sample(1000, 0.40), isClaudeFiveHour: true)
        let fiveOutcome = five.ingest(sample(1300, 0.995), isClaudeFiveHour: true) // not-started
        XCTAssertEqual(fiveOutcome, .accepted(previous: sample(1000, 0.40), didReset: true))
    }

    func testOutOfOrderTimestampIsRejectedAndFlagsIneligible() {
        var series = UsageWindowSeries(kind: .fiveHour)
        _ = series.ingest(sample(2000, 0.50), isClaudeFiveHour: true)
        let outcome = series.ingest(sample(1000, 0.60), isClaudeFiveHour: true) // clock rollback
        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(series.samples.count, 1)
        XCTAssertFalse(series.isProjectionEligible)
    }

    func testWeeklyDownsamplesToFifteenMinuteSpacing() {
        var series = UsageWindowSeries(kind: .weekly)
        _ = series.ingest(sample(0, 1.0), isClaudeFiveHour: false)
        _ = series.ingest(sample(300, 0.99), isClaudeFiveHour: false)  // +5 min → replaces
        _ = series.ingest(sample(600, 0.98), isClaudeFiveHour: false)  // +10 min → replaces
        XCTAssertEqual(series.samples.count, 1)
        XCTAssertEqual(series.samples.last?.remaining, 0.98)
        _ = series.ingest(sample(1000, 0.97), isClaudeFiveHour: false) // >15 min → appends
        XCTAssertEqual(series.samples.count, 2)
    }

    func testFiveHourCapDropsOldest() {
        var series = UsageWindowSeries(kind: .fiveHour)
        for i in 0..<200 { _ = series.ingest(sample(Double(i) * 300, 1.0 - Double(i) * 0.001), isClaudeFiveHour: true) }
        XCTAssertEqual(series.samples.count, 144)
    }

    func testWeeklyResetReanchorsDownsampleBucket() {
        var series = UsageWindowSeries(kind: .weekly)
        // First sample at t=1000 with stable resetsAt
        let resetId = Date(timeIntervalSince1970: 10000)
        _ = series.ingest(sample(1000, 0.50, resetsAt: resetId), isClaudeFiveHour: false)
        XCTAssertEqual(series.samples.count, 1)

        // Reset at t=1300 with changed resetsAt (triggers reset because identity changed)
        let newResetIdentity = Date(timeIntervalSince1970: 20000)
        let resetOutcome = series.ingest(sample(1300, 1.0, resetsAt: newResetIdentity), isClaudeFiveHour: false)
        XCTAssertEqual(resetOutcome, .accepted(previous: sample(1000, 0.50, resetsAt: resetId), didReset: true))
        XCTAssertEqual(series.samples.count, 1) // Reset clears; reset sample is appended
        XCTAssertEqual(series.samples.last?.ts, Date(timeIntervalSince1970: 1300))

        // Sample ~5 min (300s) later: should be within 900s bucket and downsampled-REPLACED, not appended
        _ = series.ingest(sample(1600, 0.99, resetsAt: newResetIdentity), isClaudeFiveHour: false)
        XCTAssertEqual(series.samples.count, 1, "Sample within bucket should replace, not append")
        XCTAssertEqual(series.samples.last?.remaining, 0.99)
    }

    func testSubEpsilonUpwardCorrectionDoesNotSegment() {
        var series = UsageWindowSeries(kind: .fiveHour)
        _ = series.ingest(sample(1000, 0.50), isClaudeFiveHour: false)
        // +0.049 upward (< 0.05 epsilon) without metadata → no reset
        let outcome = series.ingest(sample(1300, 0.549), isClaudeFiveHour: false)
        XCTAssertEqual(outcome, .accepted(previous: sample(1000, 0.50), didReset: false))
        XCTAssertEqual(series.samples.count, 2)
    }

    func testDuplicateTimestampIsRejectedWithoutFlaggingIneligible() {
        var series = UsageWindowSeries(kind: .fiveHour)
        _ = series.ingest(sample(1000, 0.50), isClaudeFiveHour: true)
        XCTAssertTrue(series.isProjectionEligible)

        // Same timestamp should be rejected, but not flag ineligible
        let outcome = series.ingest(sample(1000, 0.60), isClaudeFiveHour: true)
        XCTAssertEqual(outcome, .rejected)
        XCTAssertEqual(series.samples.count, 1)
        XCTAssertTrue(series.isProjectionEligible, "Duplicate ts should not flag ineligible (only strictly-older does)")
    }

    func testRollingResetsAtDriftDoesNotSegment() {
        // Claude's 5h window is ROLLING: resets_at advances every poll even
        // though it's the same ongoing window. remaining decreases slightly
        // each poll (real burn), and resetsAt drifts +1s each time. None of
        // this should be mistaken for a reset — a reset requires freed
        // capacity (an upward jump in `remaining`), not a changed resetsAt.
        var series = UsageWindowSeries(kind: .fiveHour)
        let base = Date(timeIntervalSince1970: 100_000)

        let outcome0 = series.ingest(sample(0, 0.72, resetsAt: base), isClaudeFiveHour: true)
        XCTAssertEqual(outcome0, .accepted(previous: nil, didReset: false))
        XCTAssertEqual(series.samples.count, 1)
        XCTAssertEqual(series.resetIdentity, base)

        let outcome1 = series.ingest(sample(300, 0.70, resetsAt: base.addingTimeInterval(1)), isClaudeFiveHour: true)
        XCTAssertEqual(outcome1, .accepted(previous: sample(0, 0.72, resetsAt: base), didReset: false))
        XCTAssertEqual(series.samples.count, 2)
        XCTAssertEqual(series.resetIdentity, base.addingTimeInterval(1), "identity must advance with rolling drift")

        let outcome2 = series.ingest(sample(600, 0.68, resetsAt: base.addingTimeInterval(2)), isClaudeFiveHour: true)
        XCTAssertEqual(outcome2, .accepted(previous: sample(300, 0.70, resetsAt: base.addingTimeInterval(1)), didReset: false))
        XCTAssertEqual(series.samples.count, 3)
        XCTAssertEqual(series.resetIdentity, base.addingTimeInterval(2))

        let outcome3 = series.ingest(sample(900, 0.66, resetsAt: base.addingTimeInterval(3)), isClaudeFiveHour: true)
        XCTAssertEqual(outcome3, .accepted(previous: sample(600, 0.68, resetsAt: base.addingTimeInterval(2)), didReset: false))
        XCTAssertEqual(series.samples.count, 4, "raw ring must GROW, not get stuck at 1 sample")
        XCTAssertEqual(series.resetIdentity, base.addingTimeInterval(3), "identity tracks the newest rolling reset time")
    }

    func testRestorePreservesIdentityWhenLastSampleOmitsResetsAt() {
        // The live ingest path preserves a known reset identity across a
        // sample that omits `resetsAt` (transient metadata gap). Restoration
        // from persisted samples must do the same — take the LATEST non-nil
        // resetsAt, not merely the last sample's — so the projector keeps its
        // ETA bound after a restart.
        let identity = Date(timeIntervalSince1970: 100_000)
        let restored = [
            sample(0, 0.80, resetsAt: identity),
            sample(300, 0.78, resetsAt: nil),
            sample(600, 0.76, resetsAt: nil),
        ]
        let series = UsageWindowSeries(kind: .fiveHour, restoredSamples: restored)
        XCTAssertEqual(series.resetIdentity, identity, "restore must keep the latest KNOWN identity, not the nil tail")
    }

    func testRealResetStillSegmentsWithDriftedResetsAt() {
        // A genuine reset (remaining jumps UP ≥ epsilon) must still segment
        // even though resetsAt also drifted alongside it (rolling window).
        var series = UsageWindowSeries(kind: .fiveHour)
        let base = Date(timeIntervalSince1970: 100_000)
        _ = series.ingest(sample(0, 0.10, resetsAt: base), isClaudeFiveHour: true)
        let outcome = series.ingest(sample(300, 1.0, resetsAt: base.addingTimeInterval(1)), isClaudeFiveHour: true)
        XCTAssertEqual(outcome, .accepted(previous: sample(0, 0.10, resetsAt: base), didReset: true))
        XCTAssertEqual(series.samples.count, 1)
    }

    func testWeeklyCapDropsOldest() {
        var series = UsageWindowSeries(kind: .weekly)
        // Add 750 samples spaced 900s apart (within-bucket replacements get ~700 kept)
        for i in 0..<750 {
            let ts = Double(i) * 900  // 900s spacing ensures append, not replace
            let remaining = 1.0 - Double(i) * 0.0001
            _ = series.ingest(sample(ts, remaining), isClaudeFiveHour: false)
        }
        XCTAssertEqual(series.samples.count, 700, "Weekly series should cap at 700 samples")
        // Verify oldest samples are dropped: first sample should be roughly at index ~50
        XCTAssertTrue((series.samples.first?.ts.timeIntervalSince1970 ?? 0) > Double(49 * 900))
    }
}
