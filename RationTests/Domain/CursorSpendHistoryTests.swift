import XCTest
@testable import Ration

/// `CursorSpendHistoryPlanner` (what to read, when, and how a read lands) and
/// `CursorSpendTrend` (bars, average, "vs average").
@MainActor
final class CursorSpendHistoryTests: XCTestCase {
    private static func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private static func month(_ year: Int, _ month: Int) -> CursorInvoiceMonth {
        CursorInvoiceMonth(year: year, month: month)
    }

    private static func cycle(_ start: String, _ end: String, _ cents: Int, closed: Bool = true) -> CursorSpendCycle {
        CursorSpendCycle(periodStart: date(start), periodEnd: date(end), spentCents: cents, isClosed: closed)
    }

    private static var utc: Calendar { CursorSpendHistoryPlanner.utcCalendar }

    // MARK: - Months (0-indexed, UTC)

    func testMonthIsZeroIndexedUTC() {
        XCTAssertEqual(CursorSpendHistoryPlanner.month(containing: Self.date("2026-12-31T23:59:59Z")), Self.month(2026, 11))
        XCTAssertEqual(CursorSpendHistoryPlanner.month(containing: Self.date("2027-01-01T00:00:00Z")), Self.month(2027, 0))
    }

    /// The backfill before January asks for December of the PREVIOUS year
    /// first, and walks back across the year boundary.
    func testBackfillMonthsCrossTheDecemberJanuaryBoundary() {
        let months = CursorSpendHistoryPlanner.months(before: Self.date("2027-01-01T00:00:00Z"), count: 12)
        XCTAssertEqual(months.count, 12)
        XCTAssertEqual(months.first, Self.month(2026, 11), "December (11) of the previous year first")
        XCTAssertEqual(months[1], Self.month(2026, 10))
        XCTAssertEqual(months.last, Self.month(2026, 0), "down to January 2026")
    }

    func testBackfillMonthsFromMidYear() {
        let months = CursorSpendHistoryPlanner.months(before: Self.date("2026-03-01T00:00:00Z"), count: 4)
        XCTAssertEqual(months, [Self.month(2026, 1), Self.month(2026, 0), Self.month(2025, 11), Self.month(2025, 10)])
    }

    func testMonthBoundariesAreUTCFirstInstants() {
        XCTAssertEqual(CursorSpendHistoryPlanner.start(of: Self.month(2026, 11)), Self.date("2026-12-01T00:00:00Z"))
        XCTAssertEqual(CursorSpendHistoryPlanner.next(Self.month(2026, 11)), Self.month(2027, 0), "Dec → Jan of the next year")
        XCTAssertEqual(CursorSpendHistoryPlanner.start(of: Self.month(2027, 0)), Self.date("2027-01-01T00:00:00Z"))
    }

    /// Twelve closed months before `open` (UTC), oldest first.
    private static func year(before open: String, cents: Int = 100) -> [CursorSpendCycle] {
        var cycles: [CursorSpendCycle] = []
        for month in CursorSpendHistoryPlanner.months(before: date(open), count: 12).reversed() {
            let start = CursorSpendHistoryPlanner.start(of: month)
            let end = CursorSpendHistoryPlanner.start(of: CursorSpendHistoryPlanner.next(month))
            cycles.append(CursorSpendCycle(periodStart: start, periodEnd: end, spentCents: cents, isClosed: true))
        }
        return cycles
    }

    func testOwedMonthsAcrossNewYear() {
        // Settled through November; January is open: December is owed.
        let settled = Self.year(before: "2026-12-01T00:00:00Z")
        let history = CursorSpendHistory(cycles: settled)
        XCTAssertEqual(
            CursorSpendHistoryPlanner.owedMonths(history: history, currentPeriodStart: Self.date("2027-01-01T00:00:00Z")),
            [Self.month(2026, 11)]
        )
        // Asleep across two boundaries: December and January, newest first.
        XCTAssertEqual(
            CursorSpendHistoryPlanner.owedMonths(history: history, currentPeriodStart: Self.date("2027-02-01T00:00:00Z")),
            [Self.month(2027, 0), Self.month(2026, 11)]
        )
        // Same open cycle: nothing.
        XCTAssertEqual(CursorSpendHistoryPlanner.owedMonths(history: history, currentPeriodStart: Self.date("2026-12-01T00:00:00Z")), [])
    }

    func testOwedMonthsAreCappedAtTwelve() {
        let history = CursorSpendHistory(cycles: Self.year(before: "2024-01-01T00:00:00Z"))
        let months = CursorSpendHistoryPlanner.owedMonths(history: history, currentPeriodStart: Self.date("2027-01-01T00:00:00Z"))
        XCTAssertEqual(months.count, 12)
        XCTAssertEqual(months.first, Self.month(2026, 11))
        XCTAssertEqual(months.last, Self.month(2026, 0))
    }

    // MARK: - Request (what and when)

    func testFirstReadIsTheTwelveCycleBackfill() throws {
        let current = Self.date("2026-09-01T00:00:00Z")
        let request = try XCTUnwrap(CursorSpendHistoryPlanner.request(
            history: CursorSpendHistory(), currentPeriodStart: current, now: Self.date("2026-09-10T12:00:00Z"), calendar: Self.utc
        ))
        XCTAssertEqual(request.months.count, 12)
        XCTAssertEqual(request.months.first, Self.month(2026, 7))
        XCTAssertEqual(request.currentPeriodStart, current)
    }

    func testNothingIsOwedOnceEveryMonthIsSettled() {
        let current = Self.date("2026-09-01T00:00:00Z")
        var cycles = Self.year(before: "2026-09-01T00:00:00Z")
        let empty = cycles.prefix(3).map { CursorSpendHistoryPlanner.month(containing: $0.periodStart) }
        cycles.removeFirst(3)
        let history = CursorSpendHistory(cycles: cycles, settledEmptyMonths: empty, syncedThrough: current)
        XCTAssertNil(CursorSpendHistoryPlanner.request(
            history: history, currentPeriodStart: current, now: Self.date("2026-09-20T00:00:00Z"), calendar: Self.utc
        ))
    }

    func testRolloverAsksForTheCycleThatJustClosed() throws {
        let history = CursorSpendHistory(
            cycles: Self.year(before: "2026-09-01T00:00:00Z"),
            syncedThrough: Self.date("2026-09-01T00:00:00Z"),
            lastAttemptAt: Self.date("2026-09-30T23:00:00Z"),
            lastAttemptCycleStart: Self.date("2026-09-01T00:00:00Z")
        )
        // Same calendar day as the last attempt, but the cycle rolled over: go.
        let request = try XCTUnwrap(CursorSpendHistoryPlanner.request(
            history: history, currentPeriodStart: Self.date("2026-10-01T00:00:00Z"),
            now: Self.date("2026-10-01T00:05:00Z"), calendar: Self.utcShifted(hours: -3)
        ))
        XCTAssertEqual(request.months, [Self.month(2026, 8)])
    }

    /// A failed read for the same cycle waits for another calendar day.
    func testAFailedReadIsRetriedOnALaterDayOnly() {
        let current = Self.date("2026-09-01T00:00:00Z")
        let history = CursorSpendHistory(
            lastAttemptAt: Self.date("2026-09-10T08:00:00Z"),
            lastAttemptCycleStart: current
        )
        XCTAssertNil(CursorSpendHistoryPlanner.request(
            history: history, currentPeriodStart: current, now: Self.date("2026-09-10T23:59:00Z"), calendar: Self.utc
        ), "same day: no retry")
        XCTAssertNotNil(CursorSpendHistoryPlanner.request(
            history: history, currentPeriodStart: current, now: Self.date("2026-09-11T00:01:00Z"), calendar: Self.utc
        ), "next day: retry")
    }

    private static func utcShifted(hours: Int) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: hours * 3600)!
        return calendar
    }

    // MARK: - Merge

    private func request(_ months: [CursorInvoiceMonth], current: String) -> CursorHistoryRequest {
        CursorHistoryRequest(months: months, currentPeriodStart: Self.date(current))
    }

    func testBackfillLandsClosedCyclesAndMarksTheHistorySynced() {
        let req = request([Self.month(2026, 7), Self.month(2026, 6)], current: "2026-09-01T00:00:00Z")
        let fetch = CursorHistoryFetch(
            cycles: [
                Self.cycle("2026-07-01T00:00:00Z", "2026-08-01T00:00:00Z", 3410),
                Self.cycle("2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z", 2410),
            ],
            historyExhausted: false, oldestEventAt: Self.date("2026-06-15T00:00:00Z")
        )
        let merged = CursorSpendHistoryPlanner.merged(CursorSpendHistory(), fetch: fetch, request: req, now: Self.date("2026-09-02T00:00:00Z"))
        XCTAssertEqual(merged.cycles.map(\.spentCents), [3410, 2410], "oldest first")
        XCTAssertEqual(merged.syncedThrough, Self.date("2026-09-01T00:00:00Z"))
    }

    /// A stored cycle never changes, and a rollover read that lands twice
    /// appends its cycle once.
    func testRolloverAppendsExactlyOnceAndClosedCyclesNeverChange() {
        let stored = Self.cycle("2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z", 2410)
        // Every earlier month of the window already settled.
        var earlier = Self.year(before: "2026-08-01T00:00:00Z")
        earlier.removeFirst()
        let history = CursorSpendHistory(cycles: earlier + [stored], syncedThrough: Self.date("2026-09-01T00:00:00Z"))
        let req = request([Self.month(2026, 8)], current: "2026-10-01T00:00:00Z")
        let september = Self.cycle("2026-09-01T00:00:00Z", "2026-10-01T00:00:00Z", 4120)
        let fetch = CursorHistoryFetch(cycles: [september], historyExhausted: false, oldestEventAt: nil)
        let now = Self.date("2026-10-01T00:10:00Z")

        let once = CursorSpendHistoryPlanner.merged(history, fetch: fetch, request: req, now: now)
        XCTAssertEqual(Array(once.cycles.suffix(2)), [stored, september])
        let twice = CursorSpendHistoryPlanner.merged(once, fetch: fetch, request: req, now: now)
        XCTAssertEqual(twice.cycles, once.cycles, "appended exactly once")
        XCTAssertEqual(twice.cycles.filter { $0.periodStart == september.periodStart }.count, 1)

        // A read that disagrees about a stored cycle does not rewrite it.
        let rewrite = CursorHistoryFetch(
            cycles: [Self.cycle("2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z", 9999)],
            historyExhausted: false, oldestEventAt: nil
        )
        let rewriteRequest = request([Self.month(2026, 7)], current: "2026-10-01T00:00:00Z")
        let unchanged = CursorSpendHistoryPlanner.merged(twice, fetch: rewrite, request: rewriteRequest, now: now)
        XCTAssertEqual(unchanged.cycles.first { $0.periodStart == stored.periodStart }?.spentCents, 2410)
        XCTAssertEqual(CursorSpendHistoryPlanner.request(
            history: unchanged, currentPeriodStart: Self.date("2026-10-01T00:00:00Z"), now: now, calendar: Self.utc
        ), nil, "nothing owed after the rollover landed")
    }

    /// Only closed cycles before the open one, from months that were asked for.
    func testMergeRejectsOpenFutureAndUnaskedCycles() {
        let req = request([Self.month(2026, 7)], current: "2026-09-01T00:00:00Z")
        let now = Self.date("2026-09-02T00:00:00Z")
        let fetch = CursorHistoryFetch(
            cycles: [
                Self.cycle("2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z", 100, closed: false),
                Self.cycle("2026-06-01T00:00:00Z", "2026-07-01T00:00:00Z", 200),
                Self.cycle("2026-09-01T00:00:00Z", "2026-09-02T00:00:00Z", 300),
            ],
            historyExhausted: false, oldestEventAt: nil
        )
        let merged = CursorSpendHistoryPlanner.merged(CursorSpendHistory(), fetch: fetch, request: req, now: now)
        XCTAssertEqual(merged.cycles, [])
    }

    /// When the walk read the whole list, a month that ends before the
    /// account's oldest event is before it was used — not a "$0 cycle".
    func testMonthsBeforeTheFirstEventAreLeftOut() {
        let req = request([Self.month(2026, 7), Self.month(2026, 6), Self.month(2026, 5)], current: "2026-09-01T00:00:00Z")
        let fetch = CursorHistoryFetch(
            cycles: [
                Self.cycle("2026-06-01T00:00:00Z", "2026-07-01T00:00:00Z", 0),
                Self.cycle("2026-07-01T00:00:00Z", "2026-08-01T00:00:00Z", 0),
                Self.cycle("2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z", 0),
            ],
            historyExhausted: true, oldestEventAt: Self.date("2026-07-20T00:00:00Z")
        )
        let merged = CursorSpendHistoryPlanner.merged(CursorSpendHistory(), fetch: fetch, request: req, now: Self.date("2026-09-02T00:00:00Z"))
        XCTAssertEqual(merged.cycles.map(\.periodStart), [Self.date("2026-07-01T00:00:00Z"), Self.date("2026-08-01T00:00:00Z")],
                       "July (has events, $0 charged) and August stay; June predates the first event")
        XCTAssertEqual(merged.settledEmptyMonths, [Self.month(2026, 5)], "June is settled empty, not stored")
        let next = CursorSpendHistoryPlanner.owedMonths(history: merged, currentPeriodStart: Self.date("2026-09-01T00:00:00Z"))
        XCTAssertFalse(next.contains(Self.month(2026, 5)), "June is not asked for again")
        XCTAssertFalse(next.contains(Self.month(2026, 7)))

        let none = CursorHistoryFetch(cycles: fetch.cycles, historyExhausted: true, oldestEventAt: nil)
        XCTAssertEqual(
            CursorSpendHistoryPlanner.merged(CursorSpendHistory(), fetch: none, request: req, now: Self.date("2026-09-02T00:00:00Z")).cycles,
            [], "no events at all: no past cycle"
        )
        // Not exhausted: every covered cycle counts, $0 included.
        let partial = CursorHistoryFetch(cycles: fetch.cycles, historyExhausted: false, oldestEventAt: Self.date("2026-05-20T00:00:00Z"))
        XCTAssertEqual(
            CursorSpendHistoryPlanner.merged(CursorSpendHistory(), fetch: partial, request: req, now: Self.date("2026-09-02T00:00:00Z")).cycles.count,
            3
        )
    }

    /// A walk stopped by its page cap settles only the months it finished;
    /// the older ones stay owed and are asked for again on the next read.
    func testCappedWalkLeavesTheUnfinishedMonthsOwed() throws {
        let open = Self.date("2026-09-01T00:00:00Z")
        let backfill = try XCTUnwrap(CursorSpendHistoryPlanner.request(
            history: CursorSpendHistory(), currentPeriodStart: open, now: Self.date("2026-09-10T00:00:00Z"), calendar: Self.utc
        ))
        // The script covered only August and July before its cap.
        let fetch = CursorHistoryFetch(
            cycles: [
                Self.cycle("2026-07-01T00:00:00Z", "2026-08-01T00:00:00Z", 3410),
                Self.cycle("2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z", 2410),
            ],
            historyExhausted: false, oldestEventAt: Self.date("2026-06-30T00:00:00Z")
        )
        let merged = CursorSpendHistoryPlanner.merged(
            CursorSpendHistory(), fetch: fetch, request: backfill, now: Self.date("2026-09-10T00:05:00Z")
        )
        XCTAssertEqual(merged.settledEmptyMonths, [])
        let next = try XCTUnwrap(CursorSpendHistoryPlanner.request(
            history: merged, currentPeriodStart: open, now: Self.date("2026-09-11T00:00:00Z"), calendar: Self.utc
        ), "the rest is still owed on a later day")
        XCTAssertEqual(next.months.count, 10)
        XCTAssertEqual(next.months.first, Self.month(2026, 5))
        XCTAssertEqual(next.months.last, Self.month(2025, 8))
    }

    func testAtMostTwelveCyclesAreKept() {
        var cycles: [CursorSpendCycle] = []
        var months: [CursorInvoiceMonth] = []
        for index in 0..<14 {
            let start = Self.utc.date(byAdding: .month, value: index, to: Self.date("2025-01-01T00:00:00Z"))!
            let end = Self.utc.date(byAdding: .month, value: 1, to: start)!
            cycles.append(CursorSpendCycle(periodStart: start, periodEnd: end, spentCents: index, isClosed: true))
            months.append(CursorSpendHistoryPlanner.month(containing: start))
        }
        let req = CursorHistoryRequest(months: months, currentPeriodStart: Self.date("2026-03-01T00:00:00Z"))
        let merged = CursorSpendHistoryPlanner.merged(
            CursorSpendHistory(), fetch: CursorHistoryFetch(cycles: cycles, historyExhausted: false, oldestEventAt: nil),
            request: req, now: Self.date("2026-03-02T00:00:00Z")
        )
        XCTAssertEqual(merged.cycles.count, 12)
        XCTAssertEqual(merged.cycles.first?.spentCents, 2, "the two oldest are dropped")
        XCTAssertEqual(merged.cycles.last?.spentCents, 13)
    }

    /// A capped walk that settled nothing still marks a read as landed
    /// (`syncedThrough`), but History must say the history is still loading,
    /// not "no earlier cycles".
    func testCappedWalkWithNothingSettledIsNotComplete() throws {
        let open = Self.date("2026-09-01T00:00:00Z")
        let request = try XCTUnwrap(CursorSpendHistoryPlanner.request(
            history: CursorSpendHistory(), currentPeriodStart: open, now: Self.date("2026-09-10T00:00:00Z"), calendar: Self.utc
        ))
        let capped = CursorHistoryFetch(cycles: [], historyExhausted: false, oldestEventAt: Self.date("2026-08-20T00:00:00Z"))
        let merged = CursorSpendHistoryPlanner.merged(CursorSpendHistory(), fetch: capped, request: request, now: Self.date("2026-09-10T00:05:00Z"))
        XCTAssertNotNil(merged.syncedThrough, "premise: a read landed")
        let current = Self.spend(100)
        XCTAssertFalse(CursorSpendHistorySection.isComplete(history: merged, current: current))
        XCTAssertEqual(
            CursorSpendHistoryCopy.pastCyclesNote(
                complete: CursorSpendHistorySection.isComplete(history: merged, current: current), locale: L10n.en
            ),
            "Earlier cycles are read from Cursor in the background."
        )
        let settled = CursorSpendHistory(settledEmptyMonths: CursorSpendHistoryPlanner.months(before: open, count: 12))
        XCTAssertTrue(CursorSpendHistorySection.isComplete(history: settled, current: current))
    }

    func testRecordingAnAttemptTouchesNoCycle() {
        let history = CursorSpendHistory(cycles: [Self.cycle("2026-08-01T00:00:00Z", "2026-09-01T00:00:00Z", 5)])
        let next = CursorSpendHistoryPlanner.recordingAttempt(
            history, at: Self.date("2026-09-10T00:00:00Z"), currentPeriodStart: Self.date("2026-09-01T00:00:00Z")
        )
        XCTAssertEqual(next.cycles, history.cycles)
        XCTAssertEqual(next.lastAttemptAt, Self.date("2026-09-10T00:00:00Z"))
        XCTAssertEqual(next.lastAttemptCycleStart, Self.date("2026-09-01T00:00:00Z"))
    }

    // MARK: - Old-file decode

    /// A file with only `cycles` (and fields this build does not know) decodes;
    /// an entry with no keys at all is an empty history, not a thrown store.
    /// (`[UUID: …]` is written as Swift's key, value, key, value array.)
    func testDecodesAMinimalOrUnknownShapedFile() throws {
        let json = """
        [
          "7B9C3A36-4F55-4F43-9F0C-0A3E2B1D4C11",
          {
            "cycles": [{"periodStart": "2026-08-01T00:00:00Z", "periodEnd": "2026-09-01T00:00:00Z", "spentCents": 2410, "isClosed": true}],
            "someFutureField": 1
          },
          "0B2B1F4E-1F55-4A43-8F0C-1A3E2B1D4C22",
          {}
        ]
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode([UUID: CursorSpendHistory].self, from: Data(json.utf8))
        let full = try XCTUnwrap(decoded[UUID(uuidString: "7B9C3A36-4F55-4F43-9F0C-0A3E2B1D4C11")!])
        XCTAssertEqual(full.cycles.map(\.spentCents), [2410])
        XCTAssertNil(full.syncedThrough)
        XCTAssertNil(full.lastAttemptAt)
        XCTAssertEqual(decoded[UUID(uuidString: "0B2B1F4E-1F55-4A43-8F0C-1A3E2B1D4C22")!], CursorSpendHistory())
    }

    /// `snapshots.json` is untouched by this feature: a Cursor snapshot written
    /// before `periodStart` existed still decodes (and draws no current bar).
    func testPreHistorySnapshotStillDecodesAndDrawsNoCurrentBar() throws {
        let json = #"{"spentCents": 1200, "resetsAt": "2026-09-01T00:00:00Z", "planLabel": "Pro"}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let spend = try decoder.decode(CursorSpend.self, from: Data(json.utf8))
        XCTAssertNil(spend.periodStart)
        let trend = CursorSpendTrend.card(closed: [Self.cycle("2026-07-01T00:00:00Z", "2026-08-01T00:00:00Z", 10)], current: spend)
        XCTAssertNil(trend.currentBar)
    }

    // MARK: - Trend

    private static func spend(_ cents: Int, start: String = "2026-09-01T00:00:00Z") -> CursorSpend {
        CursorSpend(spentCents: cents, periodStart: date(start), resetsAt: date("2026-09-15T00:00:00Z"), planLabel: "Pro")
    }

    /// Closed cycles, `count` months before September 2026, oldest first.
    private static func closed(_ cents: [Int]) -> [CursorSpendCycle] {
        var cycles: [CursorSpendCycle] = []
        let september = date("2026-09-01T00:00:00Z")
        for (index, value) in cents.enumerated() {
            let offset = index - cents.count
            let start = utc.date(byAdding: .month, value: offset, to: september)!
            let end = utc.date(byAdding: .month, value: 1, to: start)!
            cycles.append(CursorSpendCycle(periodStart: start, periodEnd: end, spentCents: value, isClosed: true))
        }
        return cycles
    }

    /// The mockup's numbers: six closed cycles averaging $29.80, $41.20 now.
    func testCardShowsSixBarsAndTheSixCycleAverage() throws {
        let history = Self.closed([1000, 2980, 3410, 2800, 4000, 2410, 2685])
        let trend = CursorSpendTrend.card(closed: history, current: Self.spend(4120))
        XCTAssertEqual(trend.bars.count, 6, "five closed + the open one")
        XCTAssertEqual(trend.bars.map(\.spentCents), [3410, 2800, 4000, 2410, 2685, 4120])
        XCTAssertEqual(trend.bars.last?.isCurrent, true)
        XCTAssertEqual(trend.bars.dropLast().contains { $0.isCurrent }, false)
        XCTAssertEqual(trend.averagedCycles, 6, "the last six CLOSED cycles, the oldest ($10.00) excluded")
        let average = try XCTUnwrap(trend.averageCents)
        XCTAssertEqual(average, Double(2980 + 3410 + 2800 + 4000 + 2410 + 2685) / 6, accuracy: 1e-9)
        XCTAssertEqual(trend.roundedAverageCents, 3048)
        XCTAssertEqual(trend.currentVersusAverage, 35)
    }

    func testNoAverageBelowTwoClosedCycles() {
        let one = CursorSpendTrend.card(closed: Self.closed([500]), current: Self.spend(900))
        XCTAssertNil(one.averageCents)
        XCTAssertNil(one.currentVersusAverage)
        XCTAssertEqual(one.bars.map(\.spentCents), [500, 900], "just the bars that exist")

        let two = CursorSpendTrend.card(closed: Self.closed([500, 700]), current: Self.spend(900))
        XCTAssertEqual(two.averageCents, 600)
        XCTAssertEqual(two.currentVersusAverage, 50)
    }

    /// Whole percent, half away from zero, from the UNROUNDED average.
    func testPercentRoundingIsHalfAwayFromZero() {
        // Average 200: 201 → +0.5% → +1; 199 → −0.5% → −1; 200 → 0.
        let trend = CursorSpendTrend.card(closed: Self.closed([100, 300]), current: Self.spend(201))
        XCTAssertEqual(trend.percentVersusAverage(201), 1)
        XCTAssertEqual(trend.percentVersusAverage(199), -1)
        XCTAssertEqual(trend.percentVersusAverage(200), 0)
        // Average 333.33…: the unrounded mean is used (−10% exactly at 300).
        let thirds = CursorSpendTrend.card(closed: Self.closed([333, 333, 334]), current: Self.spend(300))
        XCTAssertEqual(thirds.roundedAverageCents, 333)
        XCTAssertEqual(thirds.percentVersusAverage(300), -10)
        XCTAssertEqual(thirds.percentVersusAverage(0), -100)
        // Half a cent rounds away from zero in the displayed average.
        let half = CursorSpendTrend.card(closed: Self.closed([100, 101]), current: Self.spend(0))
        XCTAssertEqual(half.roundedAverageCents, 101)
    }

    func testZeroAverageHasNoPercentage() {
        let trend = CursorSpendTrend.card(closed: Self.closed([0, 0, 0]), current: Self.spend(250))
        XCTAssertEqual(trend.averageCents, 0)
        XCTAssertNil(trend.currentVersusAverage, "no ratio against $0")
        XCTAssertFalse(trend.isAllZero)
        let zero = CursorSpendTrend.card(closed: Self.closed([0, 0]), current: Self.spend(0))
        XCTAssertTrue(zero.isAllZero)
        XCTAssertEqual(zero.bars.count, 3, "$0 bars are still drawn")
    }

    func testHistoryShowsEveryStoredCycleAndTheTwelveCycleAverage() {
        let values = Array(1...12).map { $0 * 100 }
        let trend = CursorSpendTrend.history(closed: Self.closed(values), current: Self.spend(50))
        XCTAssertEqual(trend.bars.count, 13)
        XCTAssertEqual(trend.averagedCycles, 12)
        XCTAssertEqual(trend.averageCents, 650)
    }

    /// A stored cycle at or after the open cycle's start (a stale snapshot) is
    /// not drawn twice.
    func testClosedCycleAtTheOpenStartIsNotDrawnTwice() {
        let closed = [Self.cycle("2026-09-01T00:00:00Z", "2026-10-01T00:00:00Z", 999)]
        let trend = CursorSpendTrend.card(closed: closed, current: Self.spend(10))
        XCTAssertEqual(trend.bars.map(\.spentCents), [10])
    }

    func testBarHeightsScaleToTheTallestAndKeepAStubForZero() {
        XCTAssertEqual(CursorSpendMiniBars.barHeight(cents: 0, scale: 100), CursorSpendMiniBars.minimumBarHeight)
        XCTAssertEqual(CursorSpendMiniBars.barHeight(cents: 100, scale: 100), CursorSpendMiniBars.height)
        XCTAssertEqual(CursorSpendMiniBars.barHeight(cents: 50, scale: 100), CursorSpendMiniBars.height / 2)
        XCTAssertEqual(CursorSpendMiniBars.barHeight(cents: 0, scale: 0), CursorSpendMiniBars.minimumBarHeight)
        XCTAssertFalse(CursorSpendRowView.showsBars(CursorSpendTrend.card(closed: [], current: Self.spend(5))))
        XCTAssertTrue(CursorSpendRowView.showsBars(CursorSpendTrend.card(closed: Self.closed([1]), current: Self.spend(5))))
    }
}
