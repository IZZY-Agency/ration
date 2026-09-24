import XCTest
@testable import Ration

final class FableUsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let accountID = UUID()

    // MARK: Helpers

    /// `count` consecutive hourly buckets ending at the hour before `now`,
    /// sharing `totalBurn` evenly. Each bucket has one sample.
    private func buckets(count: Int, totalBurn: Double, endingHoursAgo: Int = 1) -> [UsageHourlyBucket] {
        guard count > 0 else { return [] }
        let share = totalBurn / Double(count)
        var result: [UsageHourlyBucket] = []
        for index in 0..<count {
            let hoursAgo = Double(endingHoursAgo + index)
            let start = now.addingTimeInterval(-hoursAgo * 3_600)
            result.append(bucket(at: start, consumed: share))
        }
        return result
    }

    private func bucket(at start: Date, consumed: Double, samples: Int = 1) -> UsageHourlyBucket {
        UsageHourlyBucket(
            hourStart: start,
            tzOffsetSeconds: 0,
            consumed: consumed,
            minRemaining: 0.5,
            sampleCount: samples
        )
    }

    private func window(_ kind: UsageWindowKind, used: Double) -> UsageWindow {
        UsageWindow(kind: kind, remainingFraction: 1 - used, resetsAt: nil)
    }

    private func snapshot(weeklyUsed: Double?, fableUsed: Double?) -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            fetchedAt: now,
            fiveHour: nil,
            weekly: weeklyUsed.map { window(.weekly, used: $0) },
            modelWeekly: fableUsed.map { window(.modelWeekly, used: $0) }
        )
    }

    // MARK: Coverage floor

    func testTwentyThreeSampledWeeklyBucketsIsUnknown() {
        let weekly = buckets(count: 23, totalBurn: 0.4)
        let fable = buckets(count: 23, totalBurn: 0.4)
        XCTAssertEqual(FableUsage.verdict(weekly: weekly, fable: fable, now: now), .unknown)
    }

    func testTwentyFourSampledWeeklyBucketsDecides() {
        let weekly = buckets(count: 24, totalBurn: 0.4)
        let fable = buckets(count: 24, totalBurn: 0.4)
        XCTAssertEqual(FableUsage.verdict(weekly: weekly, fable: fable, now: now), .counts)
    }

    func testBucketsWithoutSamplesDoNotCountTowardCoverage() {
        var weekly = buckets(count: 23, totalBurn: 0.4)
        weekly.append(bucket(at: now.addingTimeInterval(-30 * 3_600), consumed: 0, samples: 0))
        XCTAssertEqual(FableUsage.verdict(weekly: weekly, fable: [], now: now), .unknown)
    }

    // MARK: Burn floor

    func testWeeklyBurnBelowFloorIsUnknown() {
        let weekly = buckets(count: 48, totalBurn: 0.019)
        XCTAssertEqual(FableUsage.verdict(weekly: weekly, fable: [], now: now), .unknown)
    }

    func testWeeklyBurnAtFloorDecides() {
        let weekly = buckets(count: 40, totalBurn: 0.02)
        XCTAssertEqual(FableUsage.verdict(weekly: weekly, fable: [], now: now), .doesNotCount)
    }

    // MARK: Ratio

    func testFableBurnAtExactlyHalfCounts() {
        let weekly = buckets(count: 32, totalBurn: 0.5)
        let fable = buckets(count: 4, totalBurn: 0.25)
        XCTAssertEqual(FableUsage.verdict(weekly: weekly, fable: fable, now: now), .counts)
    }

    func testFableBurnBelowHalfDoesNotCount() {
        let weekly = buckets(count: 32, totalBurn: 0.5)
        let fable = buckets(count: 4, totalBurn: 0.24)
        XCTAssertEqual(FableUsage.verdict(weekly: weekly, fable: fable, now: now), .doesNotCount)
    }

    func testMissingFableBucketsWithCoverageIsZeroBurn() {
        let weekly = buckets(count: 30, totalBurn: 0.3)
        XCTAssertEqual(FableUsage.verdict(weekly: weekly, fable: [], now: now), .doesNotCount)
    }

    // MARK: 7-day window

    func testBucketsOlderThanSevenDaysAreIgnored() {
        // 24 recent sampled buckets with little Fable; a huge Fable burn 8 days ago.
        let weekly = buckets(count: 24, totalBurn: 0.4)
        var fable = buckets(count: 2, totalBurn: 0.1)
        fable.append(bucket(at: now.addingTimeInterval(-8 * 86_400), consumed: 5))
        XCTAssertEqual(FableUsage.verdict(weekly: weekly, fable: fable, now: now), .doesNotCount)

        // Old weekly buckets do not supply coverage either.
        let oldWeekly = buckets(count: 30, totalBurn: 0.4, endingHoursAgo: 7 * 24 + 1)
        XCTAssertEqual(FableUsage.verdict(weekly: oldWeekly, fable: [], now: now), .unknown)
    }

    // MARK: counts(verdict:snapshot:)

    /// The cached verdict and the snapshot rule are a conservative
    /// union — a verdict hydrated before this revision can't hide Fable use
    /// the snapshot already shows.
    func testCachedCountsWinsWhenSnapshotRuleIsFalse() {
        let snap = snapshot(weeklyUsed: 0.5, fableUsed: 0)
        XCTAssertTrue(FableUsage.counts(verdict: .counts, snapshot: snap))
    }

    func testCachedDoesNotCountYieldsToSnapshotRule() {
        let heavy = snapshot(weeklyUsed: 0.5, fableUsed: 0.5)
        XCTAssertTrue(FableUsage.counts(verdict: .doesNotCount, snapshot: heavy))
        let light = snapshot(weeklyUsed: 0.5, fableUsed: 0.1)
        XCTAssertFalse(FableUsage.counts(verdict: .doesNotCount, snapshot: light))
    }

    func testNoFableWindowNeverCounts() {
        let snap = snapshot(weeklyUsed: 0.5, fableUsed: nil)
        XCTAssertFalse(FableUsage.counts(verdict: .unknown, snapshot: snap))
        XCTAssertFalse(FableUsage.counts(verdict: .counts, snapshot: snap))
        XCTAssertFalse(FableUsage.counts(verdict: .unknown, snapshot: nil))
    }

    func testFallbackFableZeroDoesNotCount() {
        XCTAssertFalse(FableUsage.counts(verdict: .unknown, snapshot: snapshot(weeklyUsed: 0, fableUsed: 0)))
        XCTAssertFalse(FableUsage.counts(verdict: .unknown, snapshot: snapshot(weeklyUsed: 0.4, fableUsed: 0)))
    }

    func testFallbackFableAtLeastHalfOfWeeklyCounts() {
        XCTAssertTrue(FableUsage.counts(verdict: .unknown, snapshot: snapshot(weeklyUsed: 0.4, fableUsed: 0.2)))
        XCTAssertTrue(FableUsage.counts(verdict: .unknown, snapshot: snapshot(weeklyUsed: 0.4, fableUsed: 0.6)))
    }

    func testFallbackFableBelowHalfOfWeeklyDoesNotCount() {
        XCTAssertFalse(FableUsage.counts(verdict: .unknown, snapshot: snapshot(weeklyUsed: 0.4, fableUsed: 0.19)))
    }
}
