import WebKit
import XCTest
@testable import Ration

/// Runs the REAL `WebUsageClient.cursorFetchScript` body in an
/// `about:blank` web view with a stubbed `fetch` and a fixed `Date.now`, so the
/// in-page month derivation, the invoice assert and the emitted payload are
/// pinned at the JS level — not only from the compact payload onwards.
///
/// The stubs are installed in the same content world the script runs in
/// (`.defaultClient`, as production does), in a separate evaluation, so the
/// script text under test is byte-for-byte the production one.
@MainActor
final class CursorFetchScriptTests: XCTestCase {
    private var webView: WKWebView!

    override func setUp() async throws {
        webView = WKWebView()
    }

    override func tearDown() async throws {
        webView = nil
    }

    // MARK: - Fixtures

    private static func ms(_ iso: String) -> Double {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: iso)!
        return date.timeIntervalSince1970 * 1000
    }

    private struct Invoice {
        var startMs: Double
        var endMs: Double
    }

    private struct Outcome {
        let result: [String: Any]?
        let invoiceRequests: [[String: Any]]
        let fetchCount: Int

        var status: Int? { (result?["status"] as? NSNumber)?.intValue }
        var body: String? { result?["body"] as? String }

        var payload: [String: Any]? {
            guard let body, !body.isEmpty else { return nil }
            let object = try? JSONSerialization.jsonObject(with: Data(body.utf8))
            return object as? [String: Any]
        }

        /// The script's "integration changed" signal: HTTP 200 with an empty body.
        var isChanged: Bool { status == 200 && body == "" }
    }

    /// Stubs `fetch` + `Date.now` in the script's content world, then runs the
    /// production script. `invoiceBody` overrides the invoice JSON (for the
    /// SPA catch-all case); `events` are `[timestamp, isChargeable, cents]`.
    private func run(
        nowMs: Double,
        invoice: Invoice,
        invoiceBody: String? = nil,
        events: [(Double, Bool, Double)] = [],
        expectedOrigin: String? = nil
    ) async throws -> Outcome {
        let invoiceJSON = invoiceBody ?? #"{"pricingDescription":{"id":"p"},"periodStartMs":"\#(Int64(invoice.startMs))","periodEndMs":"\#(Int64(invoice.endMs))"}"#
        var eventObjects: [[String: Any]] = []
        for (timestamp, chargeable, cents) in events {
            eventObjects.append([
                "timestamp": String(Int64(timestamp)),
                "isChargeable": chargeable,
                "chargedCents": cents
            ])
        }
        let eventsJSONData = try JSONSerialization.data(withJSONObject: [
            "totalUsageEventsCount": events.count,
            "usageEventsDisplay": eventObjects
        ])
        let eventsJSON = String(decoding: eventsJSONData, as: UTF8.self)

        let stub = """
        window.__ration = { invoiceRequests: [], fetchCount: 0 };
        const fixedNow = nowMs;
        Date.now = function () { return fixedNow; };
        // Pin the LOCAL calendar to UTC+14 regardless of the host's timezone,
        // so local getters disagree with the UTC ones across Dec 31 → Jan 1
        // even on a UTC CI runner. A script that switched to local accessors
        // must then ask for the wrong month.
        const localShiftMs = 14 * 3600 * 1000;
        const shifted = function (date) { return new Date(date.getTime() + localShiftMs); };
        Date.prototype.getFullYear = function () { return shifted(this).getUTCFullYear(); };
        Date.prototype.getMonth = function () { return shifted(this).getUTCMonth(); };
        Date.prototype.getDate = function () { return shifted(this).getUTCDate(); };
        window.fetch = async function (path, init) {
            window.__ration.fetchCount += 1;
            const json = { "Content-Type": "application/json" };
            if (path === "/api/auth/stripe") {
                return new Response(JSON.stringify({ membershipType: "pro", isYearlyPlan: false }), { status: 200, headers: json });
            }
            if (path === "/api/dashboard/get-monthly-invoice") {
                window.__ration.invoiceRequests.push(JSON.parse(init.body));
                return new Response(invoiceJSON, { status: 200, headers: json });
            }
            if (path === "/api/dashboard/get-filtered-usage-events") {
                return new Response(eventsJSON, { status: 200, headers: json });
            }
            return new Response("unexpected " + path, { status: 404 });
        };
        return location.origin;
        """
        let origin = try await webView.callAsyncJavaScript(
            stub,
            arguments: ["nowMs": nowMs, "invoiceJSON": invoiceJSON, "eventsJSON": eventsJSON],
            in: nil,
            contentWorld: .defaultClient
        ) as? String
        let pageOrigin = try XCTUnwrap(origin)

        let result = try await webView.callAsyncJavaScript(
            WebUsageClient.cursorFetchScriptForTesting,
            arguments: ["expectedOrigin": expectedOrigin ?? pageOrigin],
            in: nil,
            contentWorld: .defaultClient
        )
        let probe = try await webView.callAsyncJavaScript(
            "return window.__ration;",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        ) as? [String: Any]
        let requests = probe?["invoiceRequests"] as? [[String: Any]] ?? []
        let count = (probe?["fetchCount"] as? NSNumber)?.intValue ?? -1
        return Outcome(result: result as? [String: Any], invoiceRequests: requests, fetchCount: count)
    }

    private func requestedMonth(_ outcome: Outcome) -> [Int] {
        guard let request = outcome.invoiceRequests.first else { return [] }
        let month = (request["month"] as? NSNumber)?.intValue ?? -1
        let year = (request["year"] as? NSNumber)?.intValue ?? -1
        return [month, year]
    }

    // MARK: - Origin gate

    func testProductionOriginGateRefusesToRunOffCursor() async throws {
        let now = Self.ms("2026-12-15T12:00:00Z")
        let outcome = try await run(
            nowMs: now,
            invoice: Invoice(startMs: Self.ms("2026-12-01T00:00:00Z"), endMs: now - 1000),
            expectedOrigin: WebUsageClient.cursorOrigin
        )
        XCTAssertEqual(WebUsageClient.cursorOrigin, "https://cursor.com")
        XCTAssertNil(outcome.result, "off cursor.com the script returns null")
        XCTAssertEqual(outcome.fetchCount, 0, "and issues no credentialed request at all")
    }

    // MARK: - UTC month / year boundary

    /// Just after midnight UTC on Jan 1: the request is for month 0 (0-indexed)
    /// of the NEW year.
    func testJanuaryFirstJustAfterUTCMidnightAsksForJanuaryOfTheNewYear() async throws {
        let now = Self.ms("2027-01-01T00:30:00Z")
        let start = Self.ms("2027-01-01T00:00:00Z")
        let outcome = try await run(
            nowMs: now,
            invoice: Invoice(startMs: start, endMs: now - 1000),
            events: [(now - 5000, true, 150.4), (start - 1000, true, 999)]
        )
        XCTAssertEqual(requestedMonth(outcome), [0, 2027])
        XCTAssertEqual(outcome.status, 200)
        let payload = try XCTUnwrap(outcome.payload, "not CHANGED: \(outcome.body ?? "nil")")
        XCTAssertEqual((payload["periodStartMs"] as? NSNumber)?.doubleValue, start)
        XCTAssertEqual((payload["spentCents"] as? NSNumber)?.intValue, 150)
    }

    /// Just before midnight UTC on Dec 31: still December of the OLD year. The
    /// stub pins the local calendar to UTC+14, where it is already Jan 1, so a
    /// script using local month accessors fails here on any host, UTC included.
    func testDecemberThirtyFirstJustBeforeUTCMidnightAsksForDecember() async throws {
        let now = Self.ms("2026-12-31T23:30:00Z")
        let start = Self.ms("2026-12-01T00:00:00Z")
        let outcome = try await run(
            nowMs: now,
            invoice: Invoice(startMs: start, endMs: now - 1000),
            events: [(now - 60_000, true, 42.6)]
        )
        XCTAssertEqual(requestedMonth(outcome), [11, 2026], "month is 0-indexed: December is 11")
        let payload = try XCTUnwrap(outcome.payload, "not CHANGED: \(outcome.body ?? "nil")")
        XCTAssertEqual((payload["periodStartMs"] as? NSNumber)?.doubleValue, start)
        XCTAssertEqual((payload["spentCents"] as? NSNumber)?.intValue, 43)
    }

    // MARK: - Invoice assert

    /// A server that re-indexed `month` hands back a different calendar month.
    func testStartFromTheWrongMonthIsChanged() async throws {
        let now = Self.ms("2026-12-15T12:00:00Z")
        for wrongStart in ["2026-11-01T00:00:00Z", "2025-12-01T00:00:00Z"] {
            let outcome = try await run(
                nowMs: now,
                invoice: Invoice(startMs: Self.ms(wrongStart), endMs: now - 1000)
            )
            XCTAssertTrue(outcome.isChanged, "start \(wrongStart) must fail closed")
        }
    }

    /// Same calendar month, but the start is still ahead of "now".
    func testFutureStartIsChanged() async throws {
        let now = Self.ms("2026-12-15T12:00:00Z")
        let outcome = try await run(
            nowMs: now,
            invoice: Invoice(startMs: Self.ms("2026-12-20T00:00:00Z"), endMs: Self.ms("2026-12-21T00:00:00Z"))
        )
        XCTAssertTrue(outcome.isChanged)
    }

    /// The open invoice reports `periodEndMs` as the server's "now" (observed
    /// 2026-08-27) — so it may be at, just behind, or well behind the client's
    /// clock. None of that is a changed integration; the old
    /// `now < periodEndMs` containment assert rejected every one of them.
    func testDriftingOrPastEndsWithinTheMonthAreAccepted() async throws {
        let now = Self.ms("2026-12-15T12:00:00Z")
        let start = Self.ms("2026-12-01T00:00:00Z")
        for end in [now, now - 1000, now - 3_600_000, Self.ms("2026-12-02T00:00:00Z")] {
            let outcome = try await run(nowMs: now, invoice: Invoice(startMs: start, endMs: end))
            XCTAssertFalse(outcome.isChanged, "end \(end) (now \(now)) must not read as CHANGED")
            let payload = try XCTUnwrap(outcome.payload)
            XCTAssertEqual((payload["periodEndMs"] as? NSNumber)?.doubleValue, end)
        }
    }

    // MARK: - Emitted payload

    func testEmittedPayloadCarriesPeriodStartAndParsesNatively() async throws {
        let now = Self.ms("2026-08-27T12:36:07Z")
        let start = Self.ms("2026-08-01T00:00:00Z")
        let end = Self.ms("2026-08-27T12:36:06Z")
        let outcome = try await run(
            nowMs: now,
            invoice: Invoice(startMs: start, endMs: end),
            events: [(end - 10, true, 26.698150634765625), (start + 1, false, 500)]
        )
        let payload = try XCTUnwrap(outcome.payload)
        XCTAssertEqual((payload["periodStartMs"] as? NSNumber)?.doubleValue, start)
        XCTAssertEqual(payload["membershipType"] as? String, "pro")

        let spend = try await CursorProviderAdapter.parse(try XCTUnwrap(outcome.body))
        XCTAssertEqual(spend.periodStart, Date(timeIntervalSince1970: start / 1000))
        XCTAssertEqual(spend.spentCents, 27)
    }

    // MARK: - SPA catch-all

    /// A removed endpoint answers HTTP 200 with the SPA's HTML shell, so only
    /// shape validation can notice it.
    func testSPACatchAllHTMLInvoiceBodyIsChanged() async throws {
        let now = Self.ms("2026-12-15T12:00:00Z")
        let outcome = try await run(
            nowMs: now,
            invoice: Invoice(startMs: Self.ms("2026-12-01T00:00:00Z"), endMs: now),
            invoiceBody: "<!DOCTYPE html><html><head><title>Cursor</title></head><body><div id=\"__next\"></div></body></html>"
        )
        XCTAssertTrue(outcome.isChanged)
    }
}
