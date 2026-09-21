import XCTest
@testable import Ration

final class UsageSparklineModelTests: XCTestCase {
    func testNormalizedPointsMapRemainingToYInverted() {
        let samples = [
            UsageHistorySample(ts: Date(timeIntervalSince1970: 0), remaining: 1.0, resetsAt: nil),
            UsageHistorySample(ts: Date(timeIntervalSince1970: 100), remaining: 0.0, resetsAt: nil),
        ]
        let points = SparklinePath.normalizedPoints(samples, in: CGSize(width: 100, height: 20))
        XCTAssertEqual(points.first!.x, 0, accuracy: 0.5)
        XCTAssertEqual(points.first!.y, 0, accuracy: 0.5)   // remaining 1.0 → top
        XCTAssertEqual(points.last!.x, 100, accuracy: 0.5)
        XCTAssertEqual(points.last!.y, 20, accuracy: 0.5)   // remaining 0.0 → bottom
    }

    func testSinglePointIsHandledWithoutDivideByZero() {
        let one = [UsageHistorySample(ts: Date(timeIntervalSince1970: 0), remaining: 0.5, resetsAt: nil)]
        XCTAssertEqual(SparklinePath.normalizedPoints(one, in: CGSize(width: 100, height: 20)).count, 1)
    }

    func testEmptySeriesReturnsEmptyPoints() {
        XCTAssertEqual(SparklinePath.normalizedPoints([], in: CGSize(width: 100, height: 20)).count, 0)
    }

    func testMidpointInterpolatesLinearlyInTime() {
        let samples = [
            UsageHistorySample(ts: Date(timeIntervalSince1970: 0), remaining: 1.0, resetsAt: nil),
            UsageHistorySample(ts: Date(timeIntervalSince1970: 50), remaining: 0.75, resetsAt: nil),
            UsageHistorySample(ts: Date(timeIntervalSince1970: 100), remaining: 0.0, resetsAt: nil),
        ]
        let points = SparklinePath.normalizedPoints(samples, in: CGSize(width: 100, height: 20))
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points[1].x, 50, accuracy: 0.5)   // halfway through the time span
        XCTAssertEqual(points[1].y, 5, accuracy: 0.5)    // remaining 0.75 → 25% down from top
    }

    func testZeroTimeSpanDoesNotDivideByZero() {
        let sameInstant = Date(timeIntervalSince1970: 42)
        let samples = [
            UsageHistorySample(ts: sameInstant, remaining: 0.6, resetsAt: nil),
            UsageHistorySample(ts: sameInstant, remaining: 0.4, resetsAt: nil),
        ]
        let points = SparklinePath.normalizedPoints(samples, in: CGSize(width: 100, height: 20))
        XCTAssertEqual(points.count, 2)
        XCTAssertFalse(points.contains { $0.x.isNaN || $0.y.isNaN })
    }

    // MARK: - SparklineProjection.markerPoint

    /// Shared fixture: a 100s-span, two-sample series with `dataWidth` at
    /// 75% of a 100pt `fullWidth` (mirrors UsageSparkline's 0.75 reservation),
    /// so `pps == 0.75`. `last.remaining == 0.6` puts the last sample's y at
    /// `20 * (1 - 0.6) == 8`.
    private var projectionFixtureSamples: [UsageHistorySample] {
        [
            UsageHistorySample(ts: Date(timeIntervalSince1970: 0), remaining: 1.0, resetsAt: nil),
            UsageHistorySample(ts: Date(timeIntervalSince1970: 100), remaining: 0.6, resetsAt: nil),
        ]
    }

    func testProjectionMarkerExtrapolatesBeyondDataLine() throws {
        let samples = projectionFixtureSamples
        let lastSampleY = SparklinePath.normalizedPoints(
            samples, in: CGSize(width: 75, height: 20)
        ).last!.y

        // eta 20s after the last sample: etaX = 75 + 20*0.75 = 90, which is
        // inside the reserved band (<= fullWidth of 100), so this is NOT the
        // clamped case — it exercises genuine extrapolation.
        let eta = Date(timeIntervalSince1970: 120)
        let marker = try XCTUnwrap(SparklineProjection.markerPoint(
            samples: samples, eta: eta, dataWidth: 75, fullWidth: 100, height: 20
        ))

        XCTAssertGreaterThan(marker.x, 75) // leaves the data band
        XCTAssertLessThanOrEqual(marker.x, 100) // stays within the frame
        XCTAssertEqual(marker.x, 90, accuracy: 0.5)
        // Lands inside the reserved band (not clamped) → extrapolates all
        // the way to remaining == 0 (frame bottom), strictly below the last
        // sample's y. This is exactly what the old degenerate math failed
        // to do (marker == last point, y == lastSampleY).
        XCTAssertGreaterThan(marker.y, lastSampleY)
        XCTAssertEqual(marker.y, 20, accuracy: 0.5)
    }

    func testProjectionMarkerClampsToFullWidth() throws {
        let samples = projectionFixtureSamples
        // eta 1000s after the last sample: unclamped etaX = 75 + 1000*0.75 =
        // 825, far past fullWidth — must clamp to 100.
        let eta = Date(timeIntervalSince1970: 1100)
        let marker = try XCTUnwrap(SparklineProjection.markerPoint(
            samples: samples, eta: eta, dataWidth: 75, fullWidth: 100, height: 20
        ))
        XCTAssertEqual(marker.x, 100, accuracy: 0.5)
    }

    func testProjectionMarkerNilForSinglePoint() {
        let one = [UsageHistorySample(ts: Date(timeIntervalSince1970: 0), remaining: 0.5, resetsAt: nil)]
        let marker = SparklineProjection.markerPoint(
            samples: one,
            eta: Date(timeIntervalSince1970: 100),
            dataWidth: 75,
            fullWidth: 100,
            height: 20
        )
        XCTAssertNil(marker)
    }

    // MARK: - SparklineVisibility.hasMeaningfulTrend

    func testHasMeaningfulTrendFalseForFlatSeriesWithoutProjection() {
        let samples = [
            UsageHistorySample(ts: Date(timeIntervalSince1970: 0), remaining: 0.5, resetsAt: nil),
            UsageHistorySample(ts: Date(timeIntervalSince1970: 100), remaining: 0.49, resetsAt: nil),
        ]
        XCTAssertFalse(SparklineVisibility.hasMeaningfulTrend(samples: samples, projection: nil))
    }

    func testHasMeaningfulTrendTrueForTrendingSeries() {
        let samples = [
            UsageHistorySample(ts: Date(timeIntervalSince1970: 0), remaining: 0.5, resetsAt: nil),
            UsageHistorySample(ts: Date(timeIntervalSince1970: 100), remaining: 0.4, resetsAt: nil),
        ]
        XCTAssertTrue(SparklineVisibility.hasMeaningfulTrend(samples: samples, projection: nil))
    }

    func testHasMeaningfulTrendTrueWheneverProjectionIsNonNilEvenIfSeriesIsFlat() {
        let samples = [
            UsageHistorySample(ts: Date(timeIntervalSince1970: 0), remaining: 0.5, resetsAt: nil),
            UsageHistorySample(ts: Date(timeIntervalSince1970: 100), remaining: 0.5, resetsAt: nil),
        ]
        let projection = Date(timeIntervalSince1970: 200)
        XCTAssertTrue(SparklineVisibility.hasMeaningfulTrend(samples: samples, projection: projection))
    }

    func testHasMeaningfulTrendFalseForFewerThanTwoSamples() {
        XCTAssertFalse(SparklineVisibility.hasMeaningfulTrend(samples: [], projection: nil))

        let one = [UsageHistorySample(ts: Date(timeIntervalSince1970: 0), remaining: 0.5, resetsAt: nil)]
        XCTAssertFalse(SparklineVisibility.hasMeaningfulTrend(samples: one, projection: nil))
    }

    func testHasMeaningfulTrendTrueExactlyAtThreshold() {
        // Build the range from `flatThreshold` itself (0 → flatThreshold) so
        // the spread equals the threshold exactly — this robustly proves the
        // comparison is inclusive (`>=`) rather than leaning on a lucky
        // float-subtraction rounding above the boundary.
        let threshold = SparklineVisibility.flatThreshold
        let samples = [
            UsageHistorySample(ts: Date(timeIntervalSince1970: 0), remaining: 0, resetsAt: nil),
            UsageHistorySample(ts: Date(timeIntervalSince1970: 100), remaining: threshold, resetsAt: nil),
        ]
        XCTAssertTrue(SparklineVisibility.hasMeaningfulTrend(samples: samples, projection: nil))
    }

    func testHasMeaningfulTrendFalseJustBelowThreshold() {
        // A spread strictly below `flatThreshold` must read as flat.
        let samples = [
            UsageHistorySample(ts: Date(timeIntervalSince1970: 0), remaining: 0, resetsAt: nil),
            UsageHistorySample(
                ts: Date(timeIntervalSince1970: 100),
                remaining: SparklineVisibility.flatThreshold - 0.001,
                resetsAt: nil
            ),
        ]
        XCTAssertFalse(SparklineVisibility.hasMeaningfulTrend(samples: samples, projection: nil))
    }
}
