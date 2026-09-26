import WebKit
import XCTest
@testable import Ration

/// Runs the REAL `WebUsageClient.cursorHistoryScript` in an `about:blank` web
/// view with a stubbed `fetch` and a fixed `Date.now` (the
/// `CursorFetchScriptTests` pattern): per-month invoices, a paged descending
/// event list, and the guards that make a backfill fail closed.
@MainActor
final class CursorHistoryScriptTests: XCTestCase {
    private var webView: WKWebView!

    override func setUp() async throws {
        webView = WKWebView()
    }

    override func tearDown() async throws {
        webView = nil
    }

    private static func ms(_ iso: String) -> Double {
        ISO8601DateFormatter().date(from: iso)!.timeIntervalSince1970 * 1000
    }

    /// `[timestamp, isChargeable, chargedCents]`, newest first.
    private typealias Event = (Double, Bool, Double)

    private struct Outcome {
        let result: [String: Any]?
        let invoiceRequests: [[String: Any]]
        let eventRequests: [[String: Any]]
        let fetchCount: Int

        var status: Int? { (result?["status"] as? NSNumber)?.intValue }
        var body: String? { result?["body"] as? String }
        var isChanged: Bool { status == 200 && body == "" }

        var payload: [String: Any]? {
            guard let body, !body.isEmpty else { return nil }
            return (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any]
        }

        /// `periodStartMs → spentCents` of the covered cycles.
        var totals: [Double: Int] {
            var result: [Double: Int] = [:]
            for cycle in payload?["cycles"] as? [[String: Any]] ?? [] {
                let start = (cycle["periodStartMs"] as? NSNumber)?.doubleValue ?? -1
                result[start] = (cycle["spentCents"] as? NSNumber)?.intValue
            }
            return result
        }
    }

    /// - invoices: `"year-month"` (0-indexed month) → `[startMs, endMs]`.
    /// - drift: the page (1-based) from which `totalUsageEventsCount` is off by one.
    private func run(
        nowMs: Double,
        currentStartMs: Double,
        months: [(Int, Int)],
        invoices: [String: [Double]],
        events: [Event],
        drift: Int? = nil,
        invoiceStatus: Int = 200,
        invoiceBody: String? = nil,
        eventsBody: String? = nil,
        rawEvents: [[String: Any]]? = nil,
        shiftAfterFirstPage: Bool = false,
        expectedOrigin: String? = nil
    ) async throws -> Outcome {
        var eventObjects: [[String: Any]] = []
        for (timestamp, chargeable, cents) in events {
            eventObjects.append(Self.event(timestamp, chargeable, cents))
        }
        if let rawEvents {
            eventObjects = rawEvents
        }
        let eventsJSON = String(decoding: try JSONSerialization.data(withJSONObject: eventObjects), as: UTF8.self)
        let invoicesJSON = String(decoding: try JSONSerialization.data(withJSONObject: invoices), as: UTF8.self)
        let stub = """
        window.__ration = { invoiceRequests: [], eventRequests: [], fetchCount: 0 };
        const fixedNow = nowMs;
        Date.now = function () { return fixedNow; };
        // Local calendar pinned to UTC-12: every invoice start (00:00 UTC on the
        // 1st) is still the previous month locally, so local getters must fail.
        const localShiftMs = -12 * 3600 * 1000;
        const shifted = function (date) { return new Date(date.getTime() + localShiftMs); };
        Date.prototype.getFullYear = function () { return shifted(this).getUTCFullYear(); };
        Date.prototype.getMonth = function () { return shifted(this).getUTCMonth(); };
        const invoices = JSON.parse(invoicesJSON);
        const allEvents = JSON.parse(eventsJSON);
        window.fetch = async function (path, init) {
            window.__ration.fetchCount += 1;
            const json = { "Content-Type": "application/json" };
            const body = JSON.parse(init.body);
            if (path === "/api/dashboard/get-monthly-invoice") {
                window.__ration.invoiceRequests.push(body);
                if (invoiceStatus !== 200) { return new Response("", { status: invoiceStatus }); }
                if (invoiceBody !== null) { return new Response(invoiceBody, { status: 200, headers: json }); }
                const found = invoices[body.year + "-" + body.month];
                if (!found) { return new Response("<html>spa</html>", { status: 200 }); }
                const invoice = { pricingDescription: { id: "p" }, periodStartMs: String(found[0]), periodEndMs: String(found[1]) };
                return new Response(JSON.stringify(invoice), { status: 200, headers: json });
            }
            if (path === "/api/dashboard/get-filtered-usage-events") {
                window.__ration.eventRequests.push(body);
                if (eventsBody !== null) { return new Response(eventsBody, { status: 200, headers: json }); }
                const from = (body.page - 1) * body.pageSize;
                const slice = allEvents.slice(from, from + body.pageSize);
                if (shiftAfterFirstPage && body.page === 1 && !window.__ration.shifted) {
                    // Same count, shifted offsets: one already-read event is
                    // deleted and one is inserted farther down.
                    window.__ration.shifted = true;
                    allEvents.splice(5, 1);
                    const neighbour = allEvents[400];
                    allEvents.splice(400, 0, Object.assign({}, neighbour, { model: "inserted" }));
                }
                const total = (drift !== null && body.page >= drift) ? allEvents.length + 1 : allEvents.length;
                return new Response(JSON.stringify({ totalUsageEventsCount: total, usageEventsDisplay: slice }), { status: 200, headers: json });
            }
            return new Response("unexpected " + path, { status: 404 });
        };
        return location.origin;
        """
        var stubArguments: [String: Any] = [
            "nowMs": nowMs, "invoicesJSON": invoicesJSON, "eventsJSON": eventsJSON,
            "drift": NSNull(), "invoiceStatus": invoiceStatus, "eventsBody": NSNull(), "invoiceBody": NSNull(),
            "shiftAfterFirstPage": shiftAfterFirstPage
        ]
        if let invoiceBody {
            stubArguments["invoiceBody"] = invoiceBody
        }
        if let drift {
            stubArguments["drift"] = drift
        }
        if let eventsBody {
            stubArguments["eventsBody"] = eventsBody
        }
        let origin = try await webView.callAsyncJavaScript(
            stub,
            arguments: stubArguments,
            in: nil,
            contentWorld: .defaultClient
        ) as? String
        let pageOrigin = try XCTUnwrap(origin)
        var monthArguments: [[String: Int]] = []
        for (year, month) in months {
            monthArguments.append(["year": year, "month": month])
        }
        let result = try await webView.callAsyncJavaScript(
            WebUsageClient.cursorHistoryScriptForTesting,
            arguments: [
                "expectedOrigin": expectedOrigin ?? pageOrigin,
                "months": monthArguments,
                "currentPeriodStartMs": currentStartMs,
                "pauseMs": 0
            ],
            in: nil,
            contentWorld: .defaultClient
        )
        let probe = try await webView.callAsyncJavaScript(
            "return window.__ration;", arguments: [:], in: nil, contentWorld: .defaultClient
        ) as? [String: Any]
        return Outcome(
            result: result as? [String: Any],
            invoiceRequests: probe?["invoiceRequests"] as? [[String: Any]] ?? [],
            eventRequests: probe?["eventRequests"] as? [[String: Any]] ?? [],
            fetchCount: (probe?["fetchCount"] as? NSNumber)?.intValue ?? -1
        )
    }

    private static func event(_ timestamp: Double, _ chargeable: Bool, _ cents: Double) -> [String: Any] {
        ["timestamp": String(Int64(timestamp)), "isChargeable": chargeable, "chargedCents": cents,
         "model": "never-stored", "requestId": "never-stored"]
    }

    // A January 2027 open cycle with November and December 2026 behind it.
    private let now = ms("2027-01-10T12:00:00Z")
    private let jan = ms("2027-01-01T00:00:00Z")
    private let dec = ms("2026-12-01T00:00:00Z")
    private let nov = ms("2026-11-01T00:00:00Z")
    private let oct = ms("2026-10-01T00:00:00Z")

    private var twoMonths: [String: [Double]] {
        ["2026-11": [dec, jan], "2026-10": [nov, dec]]
    }

    // MARK: - Origin gate

    func testRefusesToRunOffCursor() async throws {
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: [],
            expectedOrigin: WebUsageClient.cursorOrigin
        )
        XCTAssertNil(outcome.result)
        XCTAssertEqual(outcome.fetchCount, 0)
    }

    // MARK: - Boundaries and sums

    /// Dec → Jan across the UTC year boundary: December is month 11 of 2026,
    /// and an event one millisecond either side of midnight lands in its own
    /// cycle; open-cycle events are never counted.
    func testSumsEachCycleWithinItsOwnUTCBoundaries() async throws {
        let events: [Event] = [
            (jan + 1, true, 999),         // open January cycle: not ours
            (jan, true, 888),             // Jan 1 00:00:00.000: January, not December
            (jan - 1, true, 150.4),       // Dec 31 23:59:59.999: December
            (dec + 5_000, true, 49.7),    // December
            (dec + 4_000, false, 500),    // not chargeable
            (dec - 1, true, 26.698150634765625), // Nov 30 23:59:59.999: November
            (nov, true, 42.54804992675781),      // November's first instant
            (nov - 1, true, 7),           // October: older than the oldest cycle — stops the walk
        ]
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11), (2026, 10)], invoices: twoMonths, events: events
        )
        XCTAssertEqual(outcome.invoiceRequests.count, 2)
        XCTAssertEqual(outcome.invoiceRequests.first?["month"] as? Int, 11, "December is 11 (0-indexed)")
        XCTAssertEqual(outcome.invoiceRequests.first?["year"] as? Int, 2026)
        XCTAssertEqual(outcome.invoiceRequests.last?["month"] as? Int, 10)
        let payload = try XCTUnwrap(outcome.payload, "not CHANGED: \(outcome.body ?? "nil")")
        XCTAssertEqual(outcome.totals, [dec: 200, nov: 69], "150.4 + 49.7 → 200; 26.70 + 42.55 → 69")
        XCTAssertEqual(payload["historyExhausted"] as? Bool, true, "a short page ends the list")
        XCTAssertEqual((payload["oldestEventMs"] as? NSNumber)?.doubleValue, nov - 1)
        let native = try await CursorProviderAdapter.parseHistory(
            try XCTUnwrap(outcome.body),
            request: CursorHistoryRequest(
                months: [CursorInvoiceMonth(year: 2026, month: 11), CursorInvoiceMonth(year: 2026, month: 10)],
                currentPeriodStart: Date(timeIntervalSince1970: jan / 1000)
            ),
            now: Date(timeIntervalSince1970: now / 1000)
        )
        XCTAssertEqual(native.cycles.map(\.spentCents), [69, 200])
        XCTAssertTrue(native.cycles.allSatisfy(\.isClosed))
    }

    /// The emitted payload carries totals only — never an event's model or id.
    func testPayloadCarriesTotalsOnly() async throws {
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths,
            events: [(dec + 1, true, 100), (dec - 1, true, 1)]
        )
        let body = try XCTUnwrap(outcome.body)
        XCTAssertFalse(body.contains("never-stored"))
        XCTAssertEqual(Set(try XCTUnwrap(outcome.payload).keys), ["cycles", "historyExhausted", "oldestEventMs"])
    }

    /// The walk pages with `page`/`pageSize` and stops at the first page that
    /// reaches past the oldest cycle — here page 2 of 3.
    func testPagesUntilTheOldestCycleIsCovered() async throws {
        var events: [Event] = []
        for index in 0..<260 {
            events.append((dec + Double(10_000 - index), true, 1))
        }
        for index in 0..<300 {
            events.append((nov - Double(1 + index), true, 1000))
        }
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: events
        )
        XCTAssertEqual(outcome.eventRequests.count, 3, "two pages, then page 1 again")
        XCTAssertEqual(outcome.eventRequests[1]["page"] as? Int, 2)
        XCTAssertEqual(outcome.eventRequests[1]["pageSize"] as? Int, 250)
        XCTAssertEqual(outcome.eventRequests.last?["page"] as? Int, 1, "the confirming re-read")
        XCTAssertEqual(outcome.totals, [dec: 260])
        XCTAssertEqual(outcome.payload?["historyExhausted"] as? Bool, false)
    }

    /// A walk that stops at the page cap reports only the cycles it has seen
    /// past — the older one, still partial, is left out.
    func testPageCapLeavesPartialCyclesOut() async throws {
        let cap = WebUsageClient.cursorHistoryMaxPages
        var events: [Event] = [(dec + 1, true, 5), (dec - 1, true, 5)]
        for index in 0..<(cap * 250) {
            events.append((dec - 2 - Double(index), true, 1))
        }
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11), (2026, 10)], invoices: twoMonths, events: events
        )
        XCTAssertEqual(outcome.eventRequests.count, cap + 1, "the cap, then page 1 again")
        XCTAssertEqual(outcome.totals, [dec: 5], "November is incomplete, so it is not reported")
    }

    /// Exactly 40 full pages: consuming the declared total ends the list, so
    /// the oldest cycle is complete — not owed again every day.
    func testExactlyTheCapInEventsExhaustsTheList() async throws {
        let cap = WebUsageClient.cursorHistoryMaxPages
        var events: [Event] = []
        for index in 0..<(cap * 250) {
            events.append((dec + Double(2_000_000 - index), true, 1))
        }
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: events
        )
        XCTAssertEqual(outcome.payload?["historyExhausted"] as? Bool, true)
        XCTAssertEqual(outcome.totals, [dec: cap * 250])
        XCTAssertEqual(outcome.eventRequests.count, cap + 1, "no 41st page; page 1 re-read")
    }

    /// A deletion among read events plus an insertion farther down keeps the
    /// count and shifts page 2 by one: an event would be skipped. The page-1
    /// re-read sees the list changed and fails closed.
    func testSameCountShiftFailsClosed() async throws {
        var events: [Event] = []
        for index in 0..<500 {
            events.append((dec + Double(100_000 - index), true, 1))
        }
        events.append((dec - 1, true, 1))
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: events,
            shiftAfterFirstPage: true
        )
        XCTAssertTrue(outcome.isChanged, "an understated total must not be reported")
    }

    func testEmptyListExhaustsWithNoOldestEvent() async throws {
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: []
        )
        XCTAssertEqual(outcome.totals, [dec: 0])
        XCTAssertEqual(outcome.payload?["historyExhausted"] as? Bool, true)
        XCTAssertTrue(outcome.payload?["oldestEventMs"] is NSNull)
    }

    // MARK: - Fail closed

    func testCountDriftDuringTheWalkFailsClosed() async throws {
        var events: [Event] = []
        for index in 0..<400 {
            events.append((dec + Double(10_000 - index), true, 1))
        }
        events.append((nov, true, 1))
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: events, drift: 2
        )
        XCTAssertTrue(outcome.isChanged)
    }

    func testOutOfOrderEventsFailClosed() async throws {
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths,
            events: [(dec + 1, true, 1), (dec + 2, true, 1)]
        )
        XCTAssertTrue(outcome.isChanged)
    }

    func testMalformedInCycleEventFailsClosed() async throws {
        let renamed = #"{"totalUsageEventsCount":1,"usageEventsDisplay":[{"timestamp":"\#(Int64(dec + 1))","isChargeable":"yes","chargedCents":1}]}"#
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: [], eventsBody: renamed
        )
        XCTAssertTrue(outcome.isChanged)
    }

    func testShortPageThatContradictsTheCountFailsClosed() async throws {
        let short = #"{"totalUsageEventsCount":518,"usageEventsDisplay":[]}"#
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: [], eventsBody: short
        )
        XCTAssertTrue(outcome.isChanged)
    }

    /// Re-indexed `month` (the server hands back another month) fails closed.
    func testInvoiceFromAnotherMonthFailsClosed() async throws {
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: ["2026-11": [nov, dec]], events: []
        )
        XCTAssertTrue(outcome.isChanged)
    }

    /// A past month whose invoice has not ended, or reaches into the open
    /// cycle, is not closed.
    func testOpenOrOverlappingInvoiceFailsClosed() async throws {
        let stillOpen = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: ["2026-11": [dec, now + 1000]], events: []
        )
        XCTAssertTrue(stillOpen.isChanged, "ends after now")
        let intoOpen = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: ["2026-11": [dec, jan + 1000]], events: []
        )
        XCTAssertTrue(intoOpen.isChanged, "reaches into the open cycle")
        let overlapping = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11), (2026, 10)],
            invoices: ["2026-11": [dec, jan], "2026-10": [nov, dec + 1]], events: []
        )
        XCTAssertTrue(overlapping.isChanged, "November overlaps December")
    }

    /// A closed invoice must end exactly at the next UTC month's start: an
    /// end short of it would freeze a partial total.
    func testInvoiceEndingShortOfTheMonthBoundaryFailsClosed() async throws {
        let short = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: ["2026-11": [dec, jan - 3_600_000]], events: []
        )
        XCTAssertTrue(short.isChanged)
        let lateStart = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: ["2026-11": [dec + 1, jan]], events: []
        )
        XCTAssertTrue(lateStart.isChanged)
    }

    // MARK: - Strict field types (null never becomes 0)

    func testNullChargedCentsFailsClosed() async throws {
        var bad = Self.event(dec + 10, true, 0)
        bad["chargedCents"] = NSNull()
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: [],
            rawEvents: [Self.event(dec + 20, true, 100), bad, Self.event(dec - 1, true, 1)]
        )
        XCTAssertTrue(outcome.isChanged, "a null amount is not $0")
    }

    func testStringChargedCentsFailsClosed() async throws {
        var bad = Self.event(dec + 10, true, 0)
        bad["chargedCents"] = "12.5"
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: [],
            rawEvents: [bad, Self.event(dec - 1, true, 1)]
        )
        XCTAssertTrue(outcome.isChanged)
    }

    /// A null timestamp as the first event of page 2 must not read as "older
    /// than the cycle" and end the walk early.
    func testNullTimestampAtAPageBoundaryFailsClosed() async throws {
        var raw: [[String: Any]] = []
        for index in 0..<250 {
            raw.append(Self.event(dec + Double(100_000 - index), true, 1))
        }
        var bad = Self.event(dec + 50, true, 1)
        bad["timestamp"] = NSNull()
        raw.append(bad)
        raw.append(Self.event(dec - 1, true, 1))
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: [], rawEvents: raw
        )
        XCTAssertEqual(outcome.eventRequests.count, 2, "premise: the bad event is on page 2")
        XCTAssertTrue(outcome.isChanged)
    }

    func testJunkTimestampStringFailsClosed() async throws {
        var bad = Self.event(dec + 50, true, 1)
        bad["timestamp"] = "12abc"
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: [],
            rawEvents: [bad, Self.event(dec - 1, true, 1)]
        )
        XCTAssertTrue(outcome.isChanged)
    }

    func testNonNumericCountFailsClosed() async throws {
        let body = #"{"totalUsageEventsCount":"1","usageEventsDisplay":[{"timestamp":"\#(Int64(dec - 1))","isChargeable":true,"chargedCents":1}]}"#
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: [], eventsBody: body
        )
        XCTAssertTrue(outcome.isChanged)
    }

    func testNumericInvoiceBoundariesFailClosed() async throws {
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: [:], events: [],
            invoiceBody: #"{"periodStartMs":\#(Int64(dec)),"periodEndMs":\#(Int64(jan))}"#
        )
        XCTAssertTrue(outcome.isChanged, "documented as strings")
    }

    // MARK: - Overlapping pages

    /// The list shifted under a constant count: page 2 starts with the event
    /// that ended page 1. Counting it twice would inflate December.
    func testEventRepeatedAcrossPagesFailsClosed() async throws {
        var raw: [[String: Any]] = []
        for index in 0..<250 {
            raw.append(Self.event(dec + Double(100_000 - index), true, 1))
        }
        raw.append(raw[249])
        raw.append(Self.event(dec - 1, true, 1))
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: [], rawEvents: raw
        )
        XCTAssertTrue(outcome.isChanged)
    }

    func testSPACatchAllInvoiceFailsClosed() async throws {
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11), (2026, 9)], invoices: twoMonths, events: []
        )
        XCTAssertTrue(outcome.isChanged, "October has no stubbed invoice → HTML → CHANGED")
    }

    func testInvoiceHTTPFailurePassesTheStatusThrough() async throws {
        let outcome = try await run(
            nowMs: now, currentStartMs: jan, months: [(2026, 11)], invoices: twoMonths, events: [], invoiceStatus: 401
        )
        XCTAssertEqual(outcome.status, 401)
        XCTAssertEqual(outcome.eventRequests.count, 0)
    }
}
