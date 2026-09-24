import Foundation

/// Whether an account's Fable (model-weekly) limit is one the user actually
/// spends, so switch advice ranks on it. Pure.
///
/// History decides when it is meaningful: over the last 7 days, at least
/// `minimumCoverage` weekly hourly buckets carry samples AND the weekly burn is
/// at least `minimumWeeklyBurn`. Then Fable counts iff its burn is at least
/// `ratio` × the weekly burn; a missing Fable bucket is measured zero burn.
/// Otherwise the verdict is `.unknown`. `counts` ORs the verdict with the
/// current snapshot rule: Fable used > 0 and ≥ `ratio` × weekly used.
enum FableUsage {
    enum Verdict: Equatable, Sendable {
        case counts
        case doesNotCount
        case unknown
    }

    static let lookback: TimeInterval = 7 * 86_400
    static let minimumCoverage = 24
    static let minimumWeeklyBurn = 0.02
    static let ratio = 0.5
    /// Bucket burns are sums of many small deltas; compare with a tolerance so
    /// a burn that is exactly at a boundary is not lost to rounding.
    private static let tolerance = 1e-9

    static func verdict(weekly: [UsageHourlyBucket], fable: [UsageHourlyBucket], now: Date) -> Verdict {
        let cutoff = now.addingTimeInterval(-lookback)
        let recentWeekly = weekly.filter { $0.hourStart >= cutoff }
        let recentFable = fable.filter { $0.hourStart >= cutoff }

        let coverage = recentWeekly.filter { $0.sampleCount > 0 }.count
        guard coverage >= minimumCoverage else { return .unknown }

        let weeklyBurn = burn(recentWeekly)
        guard weeklyBurn + tolerance >= minimumWeeklyBurn else { return .unknown }

        let fableBurn = burn(recentFable)
        let threshold: Double = ratio * weeklyBurn
        return fableBurn + tolerance >= threshold ? .counts : .doesNotCount
    }

    /// Resolves a verdict for ranking. No Fable window on the snapshot → false
    /// (there is nothing to rank on). Otherwise a conservative union: the
    /// cached history verdict says `.counts`, OR the snapshot being evaluated
    /// shows Fable used > 0 and ≥ `ratio` × weekly used. The verdict is
    /// hydrated after history ingestion, so it can lag the revision advice is
    /// computed for; the union means a Fable user is never sent to a
    /// Fable-exhausted target within that revision.
    static func counts(verdict: Verdict, snapshot: UsageSnapshot?) -> Bool {
        guard let snapshot, let fableWindow = snapshot.modelWeekly else { return false }
        if verdict == .counts {
            return true
        }
        let fableUsed: Double = 1 - fableWindow.remainingFraction
        guard fableUsed > tolerance else { return false }
        let weeklyUsed: Double = snapshot.weekly.map { 1 - $0.remainingFraction } ?? 0
        let threshold: Double = ratio * weeklyUsed
        return fableUsed + tolerance >= threshold
    }

    private static func burn(_ buckets: [UsageHourlyBucket]) -> Double {
        var total: Double = 0
        for bucket in buckets {
            total += bucket.consumed
        }
        return total
    }
}
