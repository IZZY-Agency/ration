import SwiftUI

/// Pure geometry for the in-card sparkline: maps a raw history series onto a
/// unit rect, x by elapsed time across the series span and y by remaining
/// fraction (inverted, so `remaining == 1` sits at the top, `remaining == 0`
/// at the bottom — visually "draining down").
enum SparklinePath {
    static func normalizedPoints(
        _ samples: [UsageHistorySample],
        in size: CGSize
    ) -> [CGPoint] {
        guard let first = samples.first, let last = samples.last else { return [] }
        // A single sample (or several sharing one instant) has no time span
        // to divide by; floor it at 1s so every point maps to x = 0 instead
        // of NaN.
        let span = max(last.ts.timeIntervalSince(first.ts), 1)
        return samples.map { sample in
            let x = size.width * (sample.ts.timeIntervalSince(first.ts) / span)
            let y = size.height * (1 - sample.remaining)
            return CGPoint(x: x, y: y)
        }
    }
}

/// Pure geometry for the dashed projection marker drawn beyond the sampled
/// data line. `UsageSparkline` reserves the right portion of its frame
/// (`fullWidth - dataWidth`) for this extrapolation so the marker has room
/// to visually separate from the last real sample instead of collapsing
/// onto it.
enum SparklineProjection {
    /// - Parameters:
    ///   - dataWidth: the width the data line (`SparklinePath.normalizedPoints`)
    ///     was rendered into; the marker continues from its scale.
    ///   - fullWidth: the sparkline frame's total width; the marker's x is
    ///     clamped to this.
    ///   - height: the sparkline frame's height, shared with the data line.
    /// - Returns: nil when there are fewer than 2 samples, the sample span
    ///   is zero, or `eta` doesn't fall after the last sample (all cases
    ///   where a pixels-per-second scale can't be derived).
    static func markerPoint(
        samples: [UsageHistorySample],
        eta: Date,
        dataWidth: CGFloat,
        fullWidth: CGFloat,
        height: CGFloat
    ) -> CGPoint? {
        guard samples.count >= 2, let first = samples.first, let last = samples.last else {
            return nil
        }
        let span = last.ts.timeIntervalSince(first.ts)
        guard span > 0 else { return nil }

        // Same pixels-per-second scale as the data line, which was drawn
        // over `dataWidth` (not `fullWidth`) precisely so this marker has
        // somewhere to extrapolate to.
        let pps = dataWidth / CGFloat(span)
        let lastY = height * (1 - CGFloat(last.remaining))
        let etaXUnclamped = dataWidth + CGFloat(eta.timeIntervalSince(last.ts)) * pps
        guard etaXUnclamped > dataWidth else { return nil }

        let clampedX = min(etaXUnclamped, fullWidth)
        // At the true (unclamped) eta, remaining reaches 0 (y == height).
        // Interpolate linearly from the last sample's y toward that so a
        // clamped (far-future) eta shows the marker partway down, while an
        // eta that lands inside the reserved band reaches the full depth.
        let fraction = (clampedX - dataWidth) / (etaXUnclamped - dataWidth)
        let y = min(max(lastY + (height - lastY) * fraction, 0), height)
        return CGPoint(x: clampedX, y: y)
    }
}

/// Decides whether a window's usage history carries enough signal to be
/// worth drawing. A flat `remaining` series (the common case for a window
/// that hasn't been touched recently) renders as a bare horizontal rule —
/// visual noise rather than information — so it's suppressed entirely.
enum SparklineVisibility {
    /// Minimum spread in `remaining` (as a fraction, e.g. 0.02 == 2
    /// percentage points) across the sampled series for it to read as an
    /// actual trend rather than a flat line.
    static let flatThreshold = 0.02

    /// - Parameters:
    ///   - samples: the window's usage history.
    ///   - projection: the projected exhaustion date, if any. A non-nil
    ///     projection only exists when the projection math found a real
    ///     downward slope (see `SparklineProjection`), so its mere presence
    ///     is sufficient evidence of a meaningful trend.
    static func hasMeaningfulTrend(samples: [UsageHistorySample], projection: Date?) -> Bool {
        if projection != nil { return true }
        guard samples.count >= 2 else { return false }
        let remainings = samples.map(\.remaining)
        guard let lo = remainings.min(), let hi = remainings.max() else { return false }
        return (hi - lo) >= flatThreshold
    }
}

/// A compact (~22pt tall) usage-history sparkline: a thin line tracing the
/// "remaining fraction" of one usage window over time, tinted by the current
/// usage tier, with an optional dashed extrapolation toward a projected
/// exhaustion time.
struct UsageSparkline: View {
    let samples: [UsageHistorySample]
    let projection: Date?
    let tierUsedFraction: Double
    var now: Date = .now

    private var tint: Color { Theme.tierColor(usedFraction: tierUsedFraction) }

    private var hasMeaningfulTrend: Bool {
        SparklineVisibility.hasMeaningfulTrend(samples: samples, projection: projection)
    }

    var body: some View {
        if hasMeaningfulTrend {
            trendContent
        } else {
            EmptyView()
        }
    }

    private var trendContent: some View {
        GeometryReader { geometry in
            // When a projection exists, reserve the right 25% of the frame
            // so the data line ends before the right edge and there's room
            // for the dashed extrapolation to actually extend beyond it
            // (see SparklineProjection.markerPoint).
            let dataWidth = projection != nil ? geometry.size.width * 0.75 : geometry.size.width
            let points = SparklinePath.normalizedPoints(
                samples,
                in: CGSize(width: dataWidth, height: geometry.size.height)
            )
            ZStack(alignment: .topLeading) {
                if points.count >= 2 {
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() {
                            path.addLine(to: point)
                        }
                    }
                    .stroke(
                        tint,
                        style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                    )

                    if let projection,
                       let markerPoint = SparklineProjection.markerPoint(
                           samples: samples,
                           eta: projection,
                           dataWidth: dataWidth,
                           fullWidth: geometry.size.width,
                           height: geometry.size.height
                       ) {
                        Path { path in
                            path.move(to: points[points.count - 1])
                            path.addLine(to: markerPoint)
                        }
                        .stroke(
                            Theme.resetAccent,
                            style: StrokeStyle(lineWidth: 1.25, lineCap: .round, dash: [3, 2])
                        )

                        Circle()
                            .fill(Theme.resetAccent)
                            .frame(width: 4, height: 4)
                            .position(markerPoint)
                    }
                }
            }
        }
        .frame(height: 22)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        Self.accessibilityText(samples: samples, projection: projection)
    }

    /// What VoiceOver reads for the sparkline: the trend, and when the limit
    /// is projected to run out. The samples are REMAINING capacity, so a line
    /// sloping down (`sparklineDown`) is usage trending UP, and the words say so.
    static func accessibilityText(
        samples: [UsageHistorySample],
        projection: Date?,
        locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> String {
        guard samples.count >= 2, let first = samples.first, let last = samples.last else {
            return LocalizedStringResource.sparklineUnavailable.string(in: locale)
        }
        let delta = last.remaining - first.remaining
        let resource: LocalizedStringResource
        if delta < -0.01 {
            resource = .sparklineDown
        } else if delta > 0.01 {
            resource = .sparklineUp
        } else {
            resource = .sparklineSteady
        }
        let trend: String = resource.string(in: locale)
        guard let projection else { return trend }
        let time: String = UsageFormatters.shortTime(projection, locale: locale, timeZone: timeZone)
        return LocalizedStringResource.sparklineProjection(trend, time).string(in: locale)
    }
}
