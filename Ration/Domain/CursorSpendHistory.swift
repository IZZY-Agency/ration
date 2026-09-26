import Foundation

/// One Cursor billing cycle's usage-based spend. Both boundaries are Cursor's
/// own `periodStartMs` / `periodEndMs` for that month's invoice, and the total
/// is the rounded sum of that window's chargeable events — the same rule the
/// per-poll `CursorSpend` uses for the open cycle.
///
/// Totals only: no event, model or id is ever kept.
struct CursorSpendCycle: Codable, Equatable, Hashable, Sendable {
    let periodStart: Date
    let periodEnd: Date
    let spentCents: Int
    /// The invoice period had ended when the total was read, so the total can
    /// no longer move. Every persisted cycle is closed; the open cycle is only
    /// ever built in memory from the latest poll (`CursorSpendTrend`).
    let isClosed: Bool
}

/// A calendar month as `get-monthly-invoice` asks for it. `month` is
/// ZERO-indexed (live-pinned 2026-07-28, docs/provider-contracts/cursor.md).
struct CursorInvoiceMonth: Codable, Equatable, Hashable, Sendable {
    let year: Int
    let month: Int
}

/// Per-account Cursor spend history, persisted in `cursor-spend-history.json`.
struct CursorSpendHistory: Codable, Equatable, Sendable {
    /// Closed cycles, oldest first, at most `CursorSpendHistoryPlanner.keptCycles`.
    var cycles: [CursorSpendCycle] = []
    /// Months settled WITHOUT a stored cycle: the account had no event at or
    /// before them (a complete walk proved it), so there is nothing to show
    /// and nothing to read again. Only months inside the kept window.
    var settledEmptyMonths: [CursorInvoiceMonth] = []
    /// The open cycle's start as of the last SUCCESSFUL read (display only:
    /// "has a read ever landed"). What is still owed is derived from
    /// `cycles` + `settledEmptyMonths`, never from this date.
    var syncedThrough: Date?
    /// When the last read was attempted, and which open cycle it was for — a
    /// failed read waits for another day unless the cycle has rolled over.
    var lastAttemptAt: Date?
    var lastAttemptCycleStart: Date?

    init(
        cycles: [CursorSpendCycle] = [],
        settledEmptyMonths: [CursorInvoiceMonth] = [],
        syncedThrough: Date? = nil,
        lastAttemptAt: Date? = nil,
        lastAttemptCycleStart: Date? = nil
    ) {
        self.cycles = cycles
        self.settledEmptyMonths = settledEmptyMonths
        self.syncedThrough = syncedThrough
        self.lastAttemptAt = lastAttemptAt
        self.lastAttemptCycleStart = lastAttemptCycleStart
    }

    private enum CodingKeys: String, CodingKey {
        case cycles, settledEmptyMonths, syncedThrough, lastAttemptAt, lastAttemptCycleStart
    }

    /// Every field is optional on decode, so a file written by an earlier
    /// build (or one with fields this build does not know) never throws the
    /// whole store away.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decodedCycles: [CursorSpendCycle]? = try c.decodeIfPresent([CursorSpendCycle].self, forKey: .cycles)
        cycles = decodedCycles ?? []
        let decodedEmpty: [CursorInvoiceMonth]? = try c.decodeIfPresent([CursorInvoiceMonth].self, forKey: .settledEmptyMonths)
        settledEmptyMonths = decodedEmpty ?? []
        syncedThrough = try c.decodeIfPresent(Date.self, forKey: .syncedThrough)
        lastAttemptAt = try c.decodeIfPresent(Date.self, forKey: .lastAttemptAt)
        lastAttemptCycleStart = try c.decodeIfPresent(Date.self, forKey: .lastAttemptCycleStart)
    }
}

/// One history read: the past months to settle, newest first, and the open
/// cycle they all lie before.
struct CursorHistoryRequest: Equatable, Sendable {
    let months: [CursorInvoiceMonth]
    let currentPeriodStart: Date
}

/// What the in-page history script established. `cycles` holds only cycles
/// whose every event was seen (a walk that stopped early leaves the older
/// ones out rather than reporting a partial total).
struct CursorHistoryFetch: Equatable, Sendable {
    let cycles: [CursorSpendCycle]
    /// The walk reached the end of the account's event list.
    let historyExhausted: Bool
    /// The oldest event the walk saw (nil = none at all).
    let oldestEventAt: Date?
}

/// When to read Cursor's past cycles, what to ask for, and how a read lands
/// in the stored history. Pure; `AppModel` owns the scheduling.
enum CursorSpendHistoryPlanner {
    /// Past cycles kept per account, and asked for by the one-time backfill.
    static let keptCycles = 12

    /// Gregorian, UTC: Cursor's invoice months are UTC calendar months.
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The invoice month `date` falls in (UTC), 0-indexed.
    static func month(containing date: Date) -> CursorInvoiceMonth {
        let parts = utcCalendar.dateComponents([.year, .month], from: date)
        let year: Int = parts.year ?? 1970
        let month: Int = (parts.month ?? 1) - 1
        return CursorInvoiceMonth(year: year, month: month)
    }

    /// The `count` months before the one `date` falls in, newest first.
    static func months(before date: Date, count: Int) -> [CursorInvoiceMonth] {
        let anchor = month(containing: date)
        var result: [CursorInvoiceMonth] = []
        for offset in stride(from: 1, through: count, by: 1) {
            result.append(shifted(anchor, by: -offset))
        }
        return result
    }

    /// A month's first instant (UTC) — and, for `month + 1`, the instant a
    /// closed invoice of `month` must end at.
    static func start(of month: CursorInvoiceMonth) -> Date {
        let components = DateComponents(year: month.year, month: month.month + 1, day: 1)
        return utcCalendar.date(from: components) ?? .distantPast
    }

    static func next(_ month: CursorInvoiceMonth) -> CursorInvoiceMonth {
        shifted(month, by: 1)
    }

    private static func index(of month: CursorInvoiceMonth) -> Int {
        month.year * 12 + month.month
    }

    private static func shifted(_ month: CursorInvoiceMonth, by offset: Int) -> CursorInvoiceMonth {
        let total: Int = index(of: month) + offset
        let year: Int = Int((Double(total) / 12).rounded(.down))
        return CursorInvoiceMonth(year: year, month: total - year * 12)
    }

    /// The months still owed for the open cycle starting `currentPeriodStart`,
    /// newest first: the `keptCycles` months before it, less those stored and
    /// those settled empty. The first read asks for all twelve (the
    /// backfill); after a rollover, the cycle that just closed; after a walk
    /// that stopped at its page cap, the older months it could not finish.
    static func owedMonths(history: CursorSpendHistory, currentPeriodStart: Date) -> [CursorInvoiceMonth] {
        var settled = Set(history.settledEmptyMonths)
        for cycle in history.cycles {
            settled.insert(month(containing: cycle.periodStart))
        }
        let window = months(before: currentPeriodStart, count: keptCycles)
        return window.filter { !settled.contains($0) }
    }

    /// The read to run for this account now, or nil: nothing is owed, or a
    /// read for this same cycle already ran today.
    static func request(
        history: CursorSpendHistory,
        currentPeriodStart: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> CursorHistoryRequest? {
        let months = owedMonths(history: history, currentPeriodStart: currentPeriodStart)
        guard !months.isEmpty else { return nil }
        guard mayAttempt(history: history, currentPeriodStart: currentPeriodStart, now: now, calendar: calendar) else {
            return nil
        }
        return CursorHistoryRequest(months: months, currentPeriodStart: currentPeriodStart)
    }

    /// At most one attempt per cycle per day: a read that failed (or timed
    /// out) is retried on a later day, or at once when the cycle rolls over.
    static func mayAttempt(
        history: CursorSpendHistory,
        currentPeriodStart: Date,
        now: Date,
        calendar: Calendar
    ) -> Bool {
        guard let last = history.lastAttemptAt else { return true }
        if history.lastAttemptCycleStart != currentPeriodStart { return true }
        return !calendar.isDate(last, inSameDayAs: now)
    }

    static func recordingAttempt(
        _ history: CursorSpendHistory,
        at moment: Date,
        currentPeriodStart: Date
    ) -> CursorSpendHistory {
        var next = history
        next.lastAttemptAt = moment
        next.lastAttemptCycleStart = currentPeriodStart
        return next
    }

    /// Lands a successful read. A cycle already stored never changes; a new one
    /// is kept only if it is closed, lies before the open cycle, is one of the
    /// months asked for, and — when the walk read the whole event list — has
    /// events at or after its end (a month older than the account's first
    /// event is not a "$0 cycle", it is before the account was used; it is
    /// recorded as settled-empty instead). A month the walk did not finish
    /// (page cap) is neither: it stays owed.
    static func merged(
        _ history: CursorSpendHistory,
        fetch: CursorHistoryFetch,
        request: CursorHistoryRequest,
        now: Date
    ) -> CursorSpendHistory {
        let asked = Set(request.months)
        var byStart: [Date: CursorSpendCycle] = [:]
        for cycle in history.cycles {
            byStart[cycle.periodStart] = cycle
        }
        var emptyMonths = Set(history.settledEmptyMonths)
        for cycle in fetch.cycles {
            guard
                cycle.isClosed,
                cycle.periodEnd <= now,
                cycle.periodEnd <= request.currentPeriodStart,
                asked.contains(month(containing: cycle.periodStart)),
                byStart[cycle.periodStart] == nil
            else { continue }
            if fetch.historyExhausted, isBeforeFirstUse(cycle, oldestEventAt: fetch.oldestEventAt) {
                emptyMonths.insert(month(containing: cycle.periodStart))
                continue
            }
            byStart[cycle.periodStart] = cycle
        }
        var next = history
        let ordered: [CursorSpendCycle] = byStart.values.sorted { $0.periodStart < $1.periodStart }
        next.cycles = Array(ordered.suffix(keptCycles))
        let window = Set(months(before: request.currentPeriodStart, count: keptCycles))
        let keptEmpty: [CursorInvoiceMonth] = emptyMonths.filter { window.contains($0) }
        next.settledEmptyMonths = keptEmpty.sorted { index(of: $0) < index(of: $1) }
        if let synced = history.syncedThrough, synced > request.currentPeriodStart {
            next.syncedThrough = synced
        } else {
            next.syncedThrough = request.currentPeriodStart
        }
        return next
    }

    private static func isBeforeFirstUse(_ cycle: CursorSpendCycle, oldestEventAt: Date?) -> Bool {
        guard let oldestEventAt else { return true }
        return cycle.periodEnd <= oldestEventAt
    }
}

/// The bars, average and comparison drawn for one Cursor account — on the
/// popover card (six bars, six-cycle average) and in History (every stored
/// cycle plus the open one, twelve-cycle average).
struct CursorSpendTrend: Equatable, Sendable {
    struct Bar: Equatable, Identifiable, Sendable {
        var id: Date { periodStart }
        let periodStart: Date
        /// nil for the open cycle: its reported end is the fetch time, not a
        /// boundary (docs/provider-contracts/cursor.md, 2026-08-27).
        let periodEnd: Date?
        let spentCents: Int
        let isCurrent: Bool
    }

    /// Oldest first; the open cycle, when known, is last.
    let bars: [Bar]
    /// Mean of the most recent closed cycles, in (fractional) cents; nil when
    /// fewer than `minimumAveragedCycles` closed cycles exist.
    let averageCents: Double?
    /// How many closed cycles the average covers.
    let averagedCycles: Int

    static let minimumAveragedCycles = 2
    static let cardBars = 6
    static let cardAveragedCycles = 6
    static let historyBars = CursorSpendHistoryPlanner.keptCycles + 1
    static let historyAveragedCycles = CursorSpendHistoryPlanner.keptCycles

    static func card(closed: [CursorSpendCycle], current: CursorSpend?) -> CursorSpendTrend {
        make(closed: closed, current: current, barLimit: cardBars, averageLimit: cardAveragedCycles)
    }

    static func history(closed: [CursorSpendCycle], current: CursorSpend?) -> CursorSpendTrend {
        make(closed: closed, current: current, barLimit: historyBars, averageLimit: historyAveragedCycles)
    }

    static func make(
        closed: [CursorSpendCycle],
        current: CursorSpend?,
        barLimit: Int,
        averageLimit: Int
    ) -> CursorSpendTrend {
        let currentStart: Date? = current?.periodStart
        var settled: [CursorSpendCycle] = closed.filter { cycle in
            guard cycle.isClosed else { return false }
            guard let currentStart else { return true }
            return cycle.periodStart < currentStart
        }
        settled.sort { $0.periodStart < $1.periodStart }

        var bars: [Bar] = []
        var closedBarCount: Int = barLimit
        var currentBar: Bar?
        if let current, let currentStart {
            currentBar = Bar(periodStart: currentStart, periodEnd: nil, spentCents: current.spentCents, isCurrent: true)
            closedBarCount -= 1
        }
        for cycle in settled.suffix(max(closedBarCount, 0)) {
            bars.append(Bar(periodStart: cycle.periodStart, periodEnd: cycle.periodEnd, spentCents: cycle.spentCents, isCurrent: false))
        }
        if let currentBar {
            bars.append(currentBar)
        }

        let averaged: [CursorSpendCycle] = Array(settled.suffix(averageLimit))
        var average: Double?
        if averaged.count >= minimumAveragedCycles {
            var sum = 0
            for cycle in averaged {
                sum += cycle.spentCents
            }
            average = Double(sum) / Double(averaged.count)
        }
        return CursorSpendTrend(bars: bars, averageCents: average, averagedCycles: averaged.count)
    }

    var currentBar: Bar? {
        guard let last = bars.last, last.isCurrent else { return nil }
        return last
    }

    /// The average rounded to whole cents, half away from zero.
    var roundedAverageCents: Int? {
        guard let averageCents else { return nil }
        return Int(averageCents.rounded(.toNearestOrAwayFromZero))
    }

    /// `cents` against the average as a whole percent, half away from zero;
    /// nil without an average or when the average is $0 (no ratio exists).
    func percentVersusAverage(_ cents: Int) -> Int? {
        guard let averageCents, averageCents > 0 else { return nil }
        let ratio: Double = (Double(cents) - averageCents) / averageCents * 100
        return Int(ratio.rounded(.toNearestOrAwayFromZero))
    }

    /// The open cycle against the average — the card's "+38%".
    var currentVersusAverage: Int? {
        guard let currentBar else { return nil }
        return percentVersusAverage(currentBar.spentCents)
    }

    /// Something is drawn, and every drawn cycle is $0.
    var isAllZero: Bool {
        guard !bars.isEmpty else { return false }
        return bars.allSatisfy { $0.spentCents == 0 }
    }

    /// The bar scale's top: the tallest bar or the average, whichever is higher.
    var scaleCents: Double {
        var top: Double = averageCents ?? 0
        for bar in bars {
            top = max(top, Double(bar.spentCents))
        }
        return top
    }
}
