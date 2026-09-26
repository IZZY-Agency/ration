import Foundation

/// Folds raw samples into capture-local hourly burn buckets. Pure.
enum UsageHourlyRollup {
    /// Gap limit for callers that do not pass one: normal (non-Low-Power) cadence.
    static let defaultGapLimit = PollSchedule.rollupGapLimit(lowPowerMode: false)

    /// Folds `sample` into `buckets`.
    ///
    /// Legacy fields (`consumed`, `minRemaining`, `sampleCount`) land in the
    /// sample's hour exactly as before v2.
    ///
    /// v2 fields: the interval [previous.ts, sample.ts] is integrated with the
    /// trapezoid rule on used = 1 − remaining, split across capture-zone hour
    /// boundaries in proportion to time. It is censored (adds nothing) when
    /// there is no previous sample, `didReset` is true, or it is longer than
    /// `gapLimit`. A part that falls in an hour with no bucket in `buckets`
    /// is dropped — observed and used together — rather than creating a
    /// phantom bucket (the store hands in last month's segment too, so an
    /// interval across a month boundary lands in both).
    ///
    /// Instance boundaries: `didReset`, and for a fixed window
    /// (`isFixedWindow`, ChatGPT) also a reset time that moved between the two
    /// samples (`resetTimeMoved`). ChatGPT's reset time is fixed within an
    /// instance, so a move means a new instance even when the meter fell
    /// across it and `detectReset` saw no refill. Claude's rolling reset time
    /// moves every poll, so it is never evidence there. A boundary is counted
    /// in `resetCount` (the sample's hour), censors the interval, and splits
    /// the hour's low-water mark into `preBoundaryMinRemaining` /
    /// `postBoundaryMinRemaining`. Legacy `consumed` still follows `didReset`
    /// alone, so History's burn figures are unchanged.
    static func fold(
        previous: UsageHistorySample?,
        sample: UsageHistorySample,
        didReset: Bool,
        isFixedWindow: Bool = false,
        gapLimit: TimeInterval = defaultGapLimit,
        into buckets: inout [Date: UsageHourlyBucket],
        timeZone: TimeZone
    ) {
        let hourStart = hourStart(for: sample.ts, timeZone: timeZone)
        let offset = timeZone.secondsFromGMT(for: sample.ts)

        let consumedDelta: Double
        if let previous, !didReset {
            consumedDelta = max(0, previous.remaining - sample.remaining)
        } else {
            consumedDelta = 0
        }

        var bucket = buckets[hourStart] ?? UsageHourlyBucket(
            hourStart: hourStart,
            tzOffsetSeconds: offset,
            consumed: 0,
            minRemaining: sample.remaining,
            sampleCount: 0
        )
        var isBoundary = didReset
        if isFixedWindow, let previous, resetTimeMoved(from: previous.resetsAt, to: sample.resetsAt) {
            isBoundary = true
        }

        let lowBeforeSample: Double = bucket.minRemaining
        let hadSamples: Bool = bucket.sampleCount > 0
        bucket.consumed += consumedDelta
        bucket.minRemaining = min(bucket.minRemaining, sample.remaining)
        bucket.sampleCount += 1
        bucket.observedSeconds = bucket.observedSeconds ?? 0
        bucket.usedSeconds = bucket.usedSeconds ?? 0
        let resetsSoFar = bucket.resetCount ?? 0
        bucket.resetCount = isBoundary ? resetsSoFar + 1 : resetsSoFar
        if isBoundary {
            // The hour's first split boundary: everything folded so far is
            // the ending instance's. A second boundary in one hour keeps the
            // first pre-low and restarts the post-low (the middle instance,
            // shorter than an hour, is dropped).
            if bucket.postBoundaryMinRemaining == nil, hadSamples {
                bucket.preBoundaryMinRemaining = lowBeforeSample
            }
            bucket.postBoundaryMinRemaining = sample.remaining
        } else if let post = bucket.postBoundaryMinRemaining {
            bucket.postBoundaryMinRemaining = min(post, sample.remaining)
        }
        buckets[hourStart] = bucket

        guard let previous, !isBoundary else { return }
        integrate(from: previous, to: sample, gapLimit: gapLimit, into: &buckets, timeZone: timeZone)
    }

    /// A reset time that moves by less than this is rounding, not a new
    /// window: a real move is a whole window (5 h or 7 days).
    static let resetTimeMoveTolerance: TimeInterval = 60

    /// Both samples carry a reset time and it moved by more than the tolerance.
    static func resetTimeMoved(from old: Date?, to new: Date?) -> Bool {
        guard let old, let new else { return false }
        return abs(new.timeIntervalSince(old)) > resetTimeMoveTolerance
    }

    /// Capture-zone clock-hour start containing `ts`, as an absolute instant.
    static func hourStart(for ts: Date, timeZone: TimeZone) -> Date {
        let offset = Double(timeZone.secondsFromGMT(for: ts))
        let local = ts.timeIntervalSince1970 + offset
        let localHourFloor = (local / 3600).rounded(.down) * 3600
        return Date(timeIntervalSince1970: localHourFloor - offset)
    }

    private static func integrate(
        from previous: UsageHistorySample,
        to sample: UsageHistorySample,
        gapLimit: TimeInterval,
        into buckets: inout [Date: UsageHourlyBucket],
        timeZone: TimeZone
    ) {
        let start = previous.ts.timeIntervalSince1970
        let end = sample.ts.timeIntervalSince1970
        let duration = end - start
        guard duration > 0, duration <= gapLimit else { return }

        let usedStart = 1 - previous.remaining
        let usedEnd = 1 - sample.remaining
        let slope = (usedEnd - usedStart) / duration

        var cursor = start
        while cursor < end {
            let key = hourStart(for: Date(timeIntervalSince1970: cursor), timeZone: timeZone)
            var pieceEnd = min(key.timeIntervalSince1970 + 3600, end)
            // Defensive: always make progress (odd zone transitions).
            if pieceEnd <= cursor { pieceEnd = end }
            let length = pieceEnd - cursor
            if var bucket = buckets[key] {
                let usedAtCursor = usedStart + slope * (cursor - start)
                let usedAtPieceEnd = usedStart + slope * (pieceEnd - start)
                let area = length * (usedAtCursor + usedAtPieceEnd) / 2
                bucket.observedSeconds = (bucket.observedSeconds ?? 0) + length
                bucket.usedSeconds = (bucket.usedSeconds ?? 0) + area
                buckets[key] = bucket
            }
            cursor = pieceEnd
        }
    }
}
