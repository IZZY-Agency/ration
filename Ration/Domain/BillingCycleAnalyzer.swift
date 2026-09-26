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

/// How a provider's usage windows move, which decides what "utilisation over a
/// billing cycle" means (spec §2).
///
/// - `rolling` (Claude 5h / weekly / model-weekly): `resets_at` advances every
///   poll and the meter is "usage in the last W hours ÷ allowance", so its time
///   average is the average load.
/// - `fixed` (ChatGPT): the meter restarts at 0 on each reset, so the metric is
///   the mean of each window instance's peak.
///
/// Always derived from the account's provider by the caller, never inferred
/// from the rollup data.
nonisolated enum WindowFamily: String, Equatable, Sendable {
    case rolling
    case fixed

    /// `nil` for Cursor, which reports its own billing cycle and has no
    /// rolling/fixed usage windows.
    init?(provider: Provider) {
        switch provider {
        case .claude: self = .rolling
        case .chatGPT: self = .fixed
        case .cursor: return nil
        }
    }
}

/// Per-cycle utilisation of one subscription window.
nonisolated struct CycleUtilizationSummary: Equatable, Sendable {
    let windowKind: UsageWindowKind
    let family: WindowFamily
    /// The headline fraction. Rolling: time-weighted mean load (Σ usedSeconds /
    /// Σ observedSeconds of v2 hours). Fixed: mean of per-instance peaks. When
    /// `isLegacyLowerBound`: the pre-v2 burn figure (cycle burn per observed
    /// window; may exceed 1.0), shown as "≥ N%".
    let capacityUtilization: Double
    /// True only for a rolling window whose v2 data is not yet sufficient: the
    /// headline is then the legacy lower bound, framed exactly as before v2.
    let isLegacyLowerBound: Bool
    let consumedAllowances: Double    // Σ consumed (net burn) over the cycle
    let daysUsed: Int
    let atCapDays: Int
    /// Watched hours for display: `watchedSeconds` in whole hours.
    let observedHours: Int
    let elapsedHours: Int
    /// The observed time behind the headline and its coverage: Σ v2 observed
    /// seconds for a rolling v2 figure; in-cycle bucket-hours × 3600 for a
    /// fixed figure and for the legacy fallback.
    let observedSeconds: Double
    /// Seconds from the cycle start to min(now, end).
    let elapsedSeconds: Double
    /// The "watched" time shown on the card. Equal to `observedSeconds`
    /// except for a fixed figure, whose sufficiency counts bucket-hours but
    /// whose display counts the measured seconds of v2 hours (a legacy hour
    /// counts as a full hour, as it always did).
    let watchedSeconds: Double

    init(
        windowKind: UsageWindowKind,
        family: WindowFamily,
        capacityUtilization: Double,
        isLegacyLowerBound: Bool,
        consumedAllowances: Double,
        daysUsed: Int,
        atCapDays: Int,
        observedHours: Int,
        elapsedHours: Int,
        observedSeconds: Double,
        elapsedSeconds: Double,
        watchedSeconds: Double? = nil
    ) {
        self.windowKind = windowKind
        self.family = family
        self.capacityUtilization = capacityUtilization
        self.isLegacyLowerBound = isLegacyLowerBound
        self.consumedAllowances = consumedAllowances
        self.daysUsed = daysUsed
        self.atCapDays = atCapDays
        self.observedHours = observedHours
        self.elapsedHours = elapsedHours
        self.observedSeconds = observedSeconds
        self.elapsedSeconds = elapsedSeconds
        if let watchedSeconds {
            self.watchedSeconds = watchedSeconds
        } else {
            self.watchedSeconds = observedSeconds
        }
    }

    var coverageFraction: Double {
        elapsedSeconds > 0 ? observedSeconds / elapsedSeconds : 0
    }
    /// A rolling v2 figure needs only its absolute observed time (the one-way
    /// switch, see `BillingCycleAnalyzer.hasEnoughV2`): a time-weighted mean is
    /// not biased by unwatched hours, so a Mac that is on less than half the
    /// time still gets a figure, and the card never flips back within a cycle.
    /// Fixed and legacy figures keep coverage ≥ 0.5 as well.
    var isSufficient: Bool {
        if family == .rolling, !isLegacyLowerBound {
            return BillingCycleAnalyzer.hasEnoughV2(observedSeconds: observedSeconds, kind: windowKind)
        }
        return BillingCycleAnalyzer.isSufficient(
            observedSeconds: observedSeconds, elapsedSeconds: elapsedSeconds, kind: windowKind)
    }
}

/// Pure and nonisolated over Sendable inputs, so a whole History pass can run
/// off the main actor. Computes the cycle-long figure from the forever-retained
/// hourly buckets (raw samples cover only about one window).
nonisolated enum BillingCycleAnalyzer {
    static let coverageThreshold = 0.5
    static let baseMinObservedHours = 12
    /// A headline off a tiny slice of the window is not representative (12h of
    /// a 168h week). Require a representative fraction of the window before a
    /// summary is "sufficient" to show a number.
    static let representativeWindowFraction = 0.25
    static let atCapRemaining = 0.05
    static let idleEpsilon = 1e-4

    /// Minimum observed hours for sufficiency, per window: the larger of a flat floor
    /// and a representative fraction of the window. weekly → max(12, ceil(0.25×168)) = 42;
    /// 5h → max(12, ceil(0.25×5)) = 12.
    static func minObservedHours(for kind: UsageWindowKind) -> Int {
        max(baseMinObservedHours, Int((representativeWindowFraction * kind.windowHours).rounded(.up)))
    }

    /// Coverage (observed ÷ elapsed) ≥ 0.5 and observed ≥ `minObservedHours`.
    static func isSufficient(observedSeconds: Double, elapsedSeconds: Double, kind: UsageWindowKind) -> Bool {
        guard elapsedSeconds > 0 else { return false }
        let coverage: Double = observedSeconds / elapsedSeconds
        let floorSeconds: Double = Double(minObservedHours(for: kind)) * 3600
        return coverage >= coverageThreshold && observedSeconds >= floorSeconds
    }

    /// The rolling v2/legacy switch: in-cycle v2 observed seconds reach
    /// `minObservedHours`. Observed seconds only grow within a cycle, so the
    /// switch is one-way: once a card shows the v2 figure it never goes back
    /// to the legacy lower bound before the next cycle.
    static func hasEnoughV2(observedSeconds: Double, kind: UsageWindowKind) -> Bool {
        observedSeconds >= Double(minObservedHours(for: kind)) * 3600
    }

    static func summarize(
        buckets: [UsageHourlyBucket],
        windowKind: UsageWindowKind,
        family: WindowFamily,
        cycle: BillingCycle,
        calendar: Calendar
    ) -> CycleUtilizationSummary {
        let upper = min(cycle.now, cycle.end)
        let inCycle = buckets
            .filter { $0.hourStart >= cycle.start && $0.hourStart < upper }
            .sorted { $0.hourStart < $1.hourStart }
        let elapsedHours = max(0, calendar.dateComponents([.hour], from: cycle.start, to: upper).hour ?? 0)
        let elapsedSeconds = max(0, upper.timeIntervalSince(cycle.start))
        let cycleBurn = inCycle.reduce(0.0) { $0 + $1.consumed }
        let days = dayCounts(inCycle)
        let bucketSeconds = Double(inCycle.count) * 3600

        switch family {
        case .fixed:
            // Coverage counts bucket-hours: every bucket, legacy or v2, holds
            // the `minRemaining` the peaks are read from. "Watched" shows the
            // measured seconds where an hour has them.
            var watched = 0.0
            for bucket in inCycle {
                watched += bucket.observedSeconds ?? 3600
            }
            return CycleUtilizationSummary(
                windowKind: windowKind,
                family: .fixed,
                capacityUtilization: meanInstancePeak(inCycle),
                isLegacyLowerBound: false,
                consumedAllowances: cycleBurn,
                daysUsed: days.used,
                atCapDays: days.atCap,
                observedHours: Int((watched / 3600).rounded(.down)),
                elapsedHours: elapsedHours,
                observedSeconds: bucketSeconds,
                elapsedSeconds: elapsedSeconds,
                watchedSeconds: watched
            )

        case .rolling:
            var observed = 0.0
            var used = 0.0
            for bucket in inCycle {
                guard let o = bucket.observedSeconds, let u = bucket.usedSeconds else { continue }
                observed += o
                used += u
            }
            if hasEnoughV2(observedSeconds: observed, kind: windowKind) {
                return CycleUtilizationSummary(
                    windowKind: windowKind,
                    family: .rolling,
                    capacityUtilization: used / observed,
                    isLegacyLowerBound: false,
                    consumedAllowances: cycleBurn,
                    daysUsed: days.used,
                    atCapDays: days.atCap,
                    observedHours: Int((observed / 3600).rounded(.down)),
                    elapsedHours: elapsedHours,
                    observedSeconds: observed,
                    elapsedSeconds: elapsedSeconds
                )
            }
            // Fewer v2 hours than the floor: the pre-v2 lower bound, framed as before.
            let weeksObserved = Double(inCycle.count) / windowKind.windowHours
            let legacy = weeksObserved > 0 ? cycleBurn / weeksObserved : 0
            return CycleUtilizationSummary(
                windowKind: windowKind,
                family: .rolling,
                capacityUtilization: legacy,
                isLegacyLowerBound: true,
                consumedAllowances: cycleBurn,
                daysUsed: days.used,
                atCapDays: days.atCap,
                observedHours: inCycle.count,
                elapsedHours: elapsedHours,
                observedSeconds: bucketSeconds,
                elapsedSeconds: elapsedSeconds
            )
        }
    }

    /// Mean over window instances of each instance's peak used fraction
    /// (1 − its lowest `minRemaining`). `buckets` are in-cycle and sorted.
    ///
    /// Bucket i is an instance BOUNDARY hour when:
    /// - `resetCount > 0` (Task 1 counted a `detectReset` in the hour), or
    /// - `resetCount` is nil (legacy or upgrade hour: unknown) and the hour's
    ///   low is higher than the previous observed hour's low minus the hour's
    ///   own `consumed` by ≥ `upwardJumpEpsilon`. Within one instance the
    ///   meter only falls, and `consumed` is exactly the sum of those falls
    ///   from the previous sample on, so low_i ≈ low_{i−1} − consumed_i. A
    ///   refill is the only way to exceed that. This catches a mid-hour reset
    ///   either in its own hour (excess ≈ 1 − max(old low, new low)) or in the
    ///   next one (excess ≈ new low at the end of the reset hour − old low),
    ///   even when no hour-level `minRemaining` jump shows. It misses only
    ///   when both instances are almost unused (< ~5 points each), where
    ///   merging them barely moves the mean. A plain jump is the special case
    ///   consumed = 0.
    /// A known `resetCount == 0` is authoritative: `detectReset` saw no reset,
    /// so a rise is a same-instance correction. A reset hidden in a gap with
    /// no upward jump at all is undetectable by either mechanism.
    ///
    /// A boundary hour written by the v2 fold carries its low-water mark split
    /// in two (`preBoundaryMinRemaining` / `postBoundaryMinRemaining`): the
    /// pre part feeds the ending instance and the post part the new one, so a
    /// peak reached only in the reset hour is kept. A boundary hour WITHOUT
    /// the split (legacy, inferred, or written before the split existed)
    /// feeds NEITHER instance: its `minRemaining` may mix the old instance's
    /// last samples with the new one's first, so giving it to either could
    /// inflate that instance's peak. Leaving it out can understate a peak by
    /// up to one hour of use, and a new instance whose only hour so far is
    /// such a boundary hour has no peak yet. The first in-cycle instance may have begun before the cycle (it
    /// counts), and the last one may be in progress (it counts with its peak
    /// so far).
    static func meanInstancePeak(_ buckets: [UsageHourlyBucket]) -> Double {
        let tolerance = 1e-10
        var peaks: [Double] = []
        var currentLow: Double?
        var previousLow: Double?

        for bucket in buckets {
            var isBoundary = false
            if let resets = bucket.resetCount {
                isBoundary = resets > 0
            } else if let prior = previousLow {
                let expected: Double = prior - bucket.consumed
                let excess: Double = bucket.minRemaining - expected
                isBoundary = excess >= UsageWindowSeries.upwardJumpEpsilon - tolerance
            }
            previousLow = bucket.minRemaining
            if isBoundary {
                // A split boundary hour (v2 fold, `resetCount > 0`): the part
                // before the boundary closes the ending instance, the part
                // after it opens the new one, so both keep their true peak.
                if bucket.resetCount != nil, let post = bucket.postBoundaryMinRemaining {
                    var closing: Double? = currentLow
                    if let pre = bucket.preBoundaryMinRemaining {
                        closing = min(currentLow ?? pre, pre)
                    }
                    if let low = closing { peaks.append(1 - low) }
                    currentLow = post
                    continue
                }
                // Legacy or inferred boundary: the low mixes both instances.
                if let low = currentLow { peaks.append(1 - low) }
                currentLow = nil
                continue
            }
            let low: Double = min(currentLow ?? bucket.minRemaining, bucket.minRemaining)
            currentLow = low
        }
        if let low = currentLow { peaks.append(1 - low) }
        guard !peaks.isEmpty else { return 0 }
        let total: Double = peaks.reduce(0, +)
        return total / Double(peaks.count)
    }

    /// Days with burn and days at the cap, grouped into capture-local civil
    /// days (same ordinal as UsageHistoryAggregator).
    private static func dayCounts(_ buckets: [UsageHourlyBucket]) -> (used: Int, atCap: Int) {
        var burnByDay: [Int: Double] = [:]
        var minRemainingByDay: [Int: Double] = [:]
        for b in buckets {
            let localSeconds: Double = b.hourStart.timeIntervalSince1970 + Double(b.tzOffsetSeconds)
            let ordinal = Int((localSeconds / 86_400).rounded(.down))
            burnByDay[ordinal, default: 0] += b.consumed
            minRemainingByDay[ordinal] = min(minRemainingByDay[ordinal] ?? 1, b.minRemaining)
        }
        let used = burnByDay.values.filter { $0 > idleEpsilon }.count
        let atCap = minRemainingByDay.values.filter { $0 <= atCapRemaining }.count
        return (used, atCap)
    }
}
