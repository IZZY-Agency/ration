import Foundation

/// The current renewal-to-renewal billing cycle for one subscription. Pure and
/// calendar-driven so every boundary/edge case is unit-tested. `calendar.timeZone`
/// is the analysis timezone; boundaries are local midnights in it.
struct BillingCycle: Equatable, Sendable {
    let start: Date   // inclusive
    let end: Date     // exclusive
    let renewalDay: Int
    let now: Date
    let calendar: Calendar

    static func == (lhs: BillingCycle, rhs: BillingCycle) -> Bool {
        lhs.start == rhs.start && lhs.end == rhs.end
            && lhs.renewalDay == rhs.renewalDay && lhs.now == rhs.now
    }

    /// Calendar days in [start, end). DST-safe (uses date components, not /86400).
    var totalDays: Int {
        calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// 1-based civil-day number of `now` within the cycle.
    var dayIndex: Int {
        (calendar.dateComponents([.day], from: start, to: now).day ?? 0) + 1
    }

    static func current(renewalDay: Int, now: Date, calendar: Calendar) -> BillingCycle {
        let clampedDay = min(max(renewalDay, 1), 31)

        // Clamped renewal midnight for the month `delta` months from now's month.
        func boundary(monthsFromNow delta: Int) -> Date {
            let startOfNowMonth = calendar.date(
                from: calendar.dateComponents([.year, .month], from: now)
            )!
            let monthAnchor = calendar.date(byAdding: .month, value: delta, to: startOfNowMonth)!
            let daysInMonth = calendar.range(of: .day, in: .month, for: monthAnchor)!.count
            var comps = calendar.dateComponents([.year, .month], from: monthAnchor)
            comps.day = min(clampedDay, daysInMonth)
            comps.hour = 0; comps.minute = 0; comps.second = 0
            return calendar.date(from: comps)!
        }

        let thisBoundary = boundary(monthsFromNow: 0)
        // Compare full Dates (NOT day integers): on a clamped renewal day the
        // unclamped `now.day >= renewalDay` test is wrong (e.g. Feb 28, day 31).
        let start = now >= thisBoundary ? thisBoundary : boundary(monthsFromNow: -1)
        let end = now >= thisBoundary ? boundary(monthsFromNow: 1) : thisBoundary
        return BillingCycle(
            start: start, end: end, renewalDay: clampedDay, now: now, calendar: calendar
        )
    }
}
