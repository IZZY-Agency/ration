import Foundation

enum BurnRateProjector {
    static let minimumSamples = 3
    static let minimumSpan: TimeInterval = 600

    static func projectedExhaustion(
        for series: UsageWindowSeries,
        now: Date,
        isAccountCurrent: Bool,
        refreshInterval: TimeInterval
    ) -> Date? {
        guard series.isProjectionEligible, isAccountCurrent else { return nil }
        var points = series.samples
        guard points.count >= minimumSamples, let last = points.last else { return nil }
        // Freshness: the latest sample must be neither too stale NOR from the
        // future (a clock rollback would otherwise make `last.ts` appear
        // "fresh" relative to a `now` that is actually behind it).
        let age = now.timeIntervalSince(last.ts)
        guard age >= 0, age <= 2 * refreshInterval else { return nil }
        guard last.ts.timeIntervalSince(points[0].ts) >= minimumSpan else { return nil }

        // Trim the single worst-residual point once (outlier robustness) when we
        // still keep ≥ minimumSamples afterward.
        if points.count > minimumSamples, let fit = leastSquares(points) {
            if let worst = points.enumerated().max(by: { lhs, rhs in
                residual(lhs.element, fit) < residual(rhs.element, fit)
            }), worst.offset != points.count - 1 {
                points.remove(at: worst.offset)
            }
        }

        // Re-verify the trimmed set still meets the sample-count and span
        // minimums: trimming the earliest point can shrink the span below
        // `minimumSpan` even though the pre-trim set satisfied it.
        guard
            points.count >= minimumSamples,
            let first = points.first,
            let trimmedLast = points.last,
            trimmedLast.ts.timeIntervalSince(first.ts) >= minimumSpan
        else { return nil }

        guard let fit = leastSquares(points), fit.slope.isFinite, fit.slope < 0 else { return nil }
        // remaining(t) = intercept + slope·(t − x0) ⇒ 0 at t = x0 − intercept/slope.
        let exhaustionT = fit.x0 - fit.intercept / fit.slope
        let eta = Date(timeIntervalSince1970: exhaustionT)
        guard eta > last.ts else { return nil }
        // Bound the ETA against the series' authoritative reset identity (not
        // only the latest sample's optional `resetsAt`): a latest sample that
        // happens to omit `resetsAt` must not bypass a known reset boundary.
        let resetBound = series.resetIdentity ?? last.resetsAt
        if let resetBound, eta >= resetBound { return nil }
        return eta
    }

    private struct Fit { let slope: Double; let intercept: Double; let x0: Double }

    private static func leastSquares(_ points: [UsageHistorySample]) -> Fit? {
        let n = Double(points.count)
        guard n >= 2 else { return nil }
        // Mean/reference-center the x-values before the fit: squaring raw epoch
        // timestamps (~1.78e9) and subtracting near-equal terms (n·sumXX − sumX²)
        // causes catastrophic cancellation. Centering on the first sample's ts
        // preserves the least-squares slope exactly (translation-invariant)
        // while keeping the magnitudes small.
        let x0 = points[0].ts.timeIntervalSince1970
        let xs = points.map { $0.ts.timeIntervalSince1970 - x0 }
        let ys = points.map { $0.remaining }
        let sumX = xs.reduce(0, +), sumY = ys.reduce(0, +)
        let sumXY = zip(xs, ys).reduce(0) { $0 + $1.0 * $1.1 }
        let sumXX = xs.reduce(0) { $0 + $1 * $1 }
        let denom = n * sumXX - sumX * sumX
        guard denom != 0 else { return nil }
        let slope = (n * sumXY - sumX * sumY) / denom
        let intercept = (sumY - slope * sumX) / n
        return Fit(slope: slope, intercept: intercept, x0: x0)
    }

    private static func residual(_ sample: UsageHistorySample, _ fit: Fit) -> Double {
        abs(sample.remaining - (fit.intercept + fit.slope * (sample.ts.timeIntervalSince1970 - fit.x0)))
    }
}
