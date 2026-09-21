import Foundation

struct DayBurn: Equatable, Sendable {
    let dayStart: Date   // capture-local midnight, as a UTC instant
    let consumed: Double
}

struct HourOfDayBurn: Equatable, Sendable {
    let hour: Int        // 0…23 capture-local
    let averageConsumed: Double
}

enum UsageHistoryAggregator {
    private static func localSeconds(_ b: UsageHourlyBucket) -> Double {
        b.hourStart.timeIntervalSince1970 + Double(b.tzOffsetSeconds)
    }

    static func hourOfDayHeatmap(_ buckets: [UsageHourlyBucket]) -> [HourOfDayBurn] {
        var totals = [Double](repeating: 0, count: 24)
        var counts = [Int](repeating: 0, count: 24)
        for b in buckets {
            let hour = Int((localSeconds(b) / 3600).rounded(.down)) % 24
            let h = (hour % 24 + 24) % 24
            totals[h] += b.consumed
            counts[h] += 1
        }
        return (0..<24).map { hour in
            HourOfDayBurn(hour: hour, averageConsumed: counts[hour] == 0 ? 0 : totals[hour] / Double(counts[hour]))
        }
    }

    static func daySeries(_ buckets: [UsageHourlyBucket]) -> [DayBurn] {
        // Key by the offset-independent capture-local civil-day ordinal, not by
        // `localDayFloor - offset` (a UTC instant): two buckets on the same
        // capture-local civil day with different `tzOffsetSeconds` (a DST
        // transition day) share the same ordinal but would otherwise produce
        // two distinct UTC-instant keys, splitting one day into two partial
        // "Daily Burn" points.
        var totals: [Int: Double] = [:]            // civil-day ordinal → consumed
        var representativeOffset: [Int: Int] = [:]  // ordinal → one contributing bucket's offset
        for b in buckets {
            let ordinal = Int((localSeconds(b) / 86_400).rounded(.down))
            totals[ordinal, default: 0] += b.consumed
            if representativeOffset[ordinal] == nil {
                representativeOffset[ordinal] = b.tzOffsetSeconds
            }
        }
        return totals.keys.sorted().map { ordinal in
            // Reconstruct a representative local-midnight instant using the
            // offset of one contributing bucket for that day.
            let offset = representativeOffset[ordinal] ?? 0
            let dayStart = Date(timeIntervalSince1970: Double(ordinal) * 86_400 - Double(offset))
            return DayBurn(dayStart: dayStart, consumed: totals[ordinal] ?? 0)
        }
    }
}
