import Foundation

extension UsageWindowKind {
    /// Length of the rolling window in hours; the normalization base for
    /// "one allowance" of burn.
    var windowHours: Double {
        switch self {
        case .fiveHour: 5
        case .weekly: 168
        case .modelWeekly: 168
        }
    }
}

/// Per-cycle utilisation of one subscription, derived from hourly rollup burn.
struct CycleUtilizationSummary: Equatable, Sendable {
    let windowKind: UsageWindowKind
    let capacityUtilization: Double   // cycleBurn / weeksObserved; may exceed 1.0
    let consumedAllowances: Double    // Σ consumed (burn) over the cycle
    let daysUsed: Int
    let atCapDays: Int
    let observedHours: Int
    let elapsedHours: Int

    var coverageFraction: Double {
        elapsedHours == 0 ? 0 : Double(observedHours) / Double(elapsedHours)
    }
    var isSufficient: Bool {
        coverageFraction >= BillingCycleAnalyzer.coverageThreshold
            && observedHours >= BillingCycleAnalyzer.minObservedHours(for: windowKind)
    }
}

/// Pure. Computes a burn-based utilisation from the forever-retained hourly
/// buckets — NOT from the rolling window's fill level (which lingers for days
/// after a burst and would measure pressure, not consumption).
enum BillingCycleAnalyzer {
    static let coverageThreshold = 0.5
    static let baseMinObservedHours = 12
    /// A headline normalized by observedHours/windowHours extrapolates wildly off a
    /// tiny slice (12h of a 168h week ⇒ ×14). Require a representative fraction of the
    /// window before a summary is "sufficient" to show a number.
    static let representativeWindowFraction = 0.25
    static let atCapRemaining = 0.05
    static let idleEpsilon = 1e-4

    /// Minimum observed hours for sufficiency, per window: the larger of a flat floor
    /// and a representative fraction of the window. weekly → max(12, ceil(0.25×168)) = 42;
    /// 5h → max(12, ceil(0.25×5)) = 12.
    static func minObservedHours(for kind: UsageWindowKind) -> Int {
        max(baseMinObservedHours, Int((representativeWindowFraction * kind.windowHours).rounded(.up)))
    }

    static func summarize(
        buckets: [UsageHourlyBucket],
        windowKind: UsageWindowKind,
        cycle: BillingCycle,
        calendar: Calendar
    ) -> CycleUtilizationSummary {
        let upper = min(cycle.now, cycle.end)
        let inCycle = buckets.filter { $0.hourStart >= cycle.start && $0.hourStart < upper }

        let cycleBurn = inCycle.reduce(0.0) { $0 + $1.consumed }
        let observedHours = inCycle.count          // one bucket per clock-hour
        let elapsedHours = max(0, calendar.dateComponents([.hour], from: cycle.start, to: upper).hour ?? 0)
        let weeksObserved = Double(observedHours) / windowKind.windowHours
        let capacityUtilization = weeksObserved > 0 ? cycleBurn / weeksObserved : 0

        // Group into capture-local civil days (same ordinal as UsageHistoryAggregator).
        var burnByDay: [Int: Double] = [:]
        var minRemainingByDay: [Int: Double] = [:]
        for b in inCycle {
            let ordinal = Int(((b.hourStart.timeIntervalSince1970 + Double(b.tzOffsetSeconds)) / 86_400).rounded(.down))
            burnByDay[ordinal, default: 0] += b.consumed
            minRemainingByDay[ordinal] = min(minRemainingByDay[ordinal] ?? 1, b.minRemaining)
        }
        let daysUsed = burnByDay.values.filter { $0 > idleEpsilon }.count
        let atCapDays = minRemainingByDay.values.filter { $0 <= atCapRemaining }.count

        return CycleUtilizationSummary(
            windowKind: windowKind,
            capacityUtilization: capacityUtilization,
            consumedAllowances: cycleBurn,
            daysUsed: daysUsed,
            atCapDays: atCapDays,
            observedHours: observedHours,
            elapsedHours: elapsedHours
        )
    }
}
