import Foundation

/// Folds raw samples into capture-local hourly burn buckets. Pure.
enum UsageHourlyRollup {
    static func fold(
        previous: UsageHistorySample?,
        sample: UsageHistorySample,
        didReset: Bool,
        into buckets: inout [Date: UsageHourlyBucket],
        timeZone: TimeZone
    ) {
        let offset = timeZone.secondsFromGMT(for: sample.ts)
        let local = sample.ts.timeIntervalSince1970 + Double(offset)
        let localHourFloor = (local / 3600).rounded(.down) * 3600
        let hourStart = Date(timeIntervalSince1970: localHourFloor - Double(offset))

        let consumedDelta: Double
        if let previous, !didReset {
            consumedDelta = max(0, previous.remaining - sample.remaining)
        } else {
            consumedDelta = 0
        }

        if var bucket = buckets[hourStart] {
            bucket.consumed += consumedDelta
            bucket.minRemaining = min(bucket.minRemaining, sample.remaining)
            bucket.sampleCount += 1
            buckets[hourStart] = bucket
        } else {
            buckets[hourStart] = UsageHourlyBucket(
                hourStart: hourStart,
                tzOffsetSeconds: offset,
                consumed: consumedDelta,
                minRemaining: sample.remaining,
                sampleCount: 1
            )
        }
    }
}
