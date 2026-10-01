import WebKit
import XCTest
@testable import Ration

@MainActor
final class ClaudeUsageCreditsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// The shape claude.ai returned for a Max 20x account on 2026-09-30, with
    /// the grant id replaced.
    private let verified = #"""
    {"amount":1000,"currency":"EUR","balance":{"money":{"amount_minor":1000,"currency":"EUR","exponent":2},"credits":null},"balance_credits":null,"amount_without_scoped_credits":1000,"auto_reload_settings":null,"auto_reload_disabled_reason":null,"auto_reload_stripe_error_code":null,"pending_invoice_amount_cents":null,"last_paid_purchase_cents":null,"expiry_policy_months":null,"tranches":[],"promo_tranches":[{"remaining_amount_minor_units":1000,"currency":"EUR","expires_at":"2027-05-27T00:00:00Z","granted_amount_minor_units":1000,"granted_at":"2026-05-27T18:27:20.819000Z","remaining":{"money":{"amount_minor":1000,"currency":"EUR","exponent":2},"credits":null},"granted":{"money":{"amount_minor":1000,"currency":"EUR","exponent":2},"credits":null},"program_id":"credit_program_v2","name":null,"id":"promo-1","scope":{"kind":"unscoped","applies_to":[]}}],"next_expires_at":"2027-05-27T00:00:00Z"}
    """#

    private func tranche(id: String = "t-1", remaining: Int = 400, granted: Int = 500, currency: String = "EUR", expires: String? = "2026-12-01T00:00:00Z") -> String {
        let expiry = expires.map { "\"\($0)\"" } ?? "null"
        return #"{"id":"\#(id)","remaining":{"money":{"amount_minor":\#(remaining),"currency":"\#(currency)","exponent":2}},"granted":{"money":{"amount_minor":\#(granted),"currency":"\#(currency)","exponent":2}},"expires_at":\#(expiry)}"#
    }

    private func body(balance: Int = 1000, promo: String = "[]", purchased: String = "[]") -> String {
        #"{"balance":{"money":{"amount_minor":\#(balance),"currency":"EUR","exponent":2}},"promo_tranches":\#(promo),"tranches":\#(purchased)}"#
    }

    private func euros(_ cents: Int64) -> Money { Money(minorUnits: cents, currency: "EUR", exponent: 2)! }

    // MARK: Decoding

    func testReadsTheVerifiedResponse() throws {
        let credits = try XCTUnwrap(ClaudeProviderAdapter.usageCredits(fromBody: verified, fetchedAt: t0))
        XCTAssertEqual(credits.fetchedAt, t0)
        XCTAssertEqual(credits.balance, euros(1000))
        XCTAssertTrue(credits.complete)
        XCTAssertEqual(credits.grants, [UsageCreditGrant(
            id: "promo-1", kind: .promotional, remaining: euros(1000), granted: euros(1000),
            expiresAt: ISO8601DateFormatter().date(from: "2027-05-27T00:00:00Z")
        )])
    }

    func testPurchasedGrantWithoutExpiry() throws {
        let credits = try XCTUnwrap(ClaudeProviderAdapter.usageCredits(fromBody: body(purchased: "[\(tranche(expires: nil))]"), fetchedAt: t0))
        XCTAssertEqual(credits.grants.map(\.kind), [.purchased])
        XCTAssertNil(credits.grants.first?.expiresAt)
        XCTAssertEqual(credits.grants.first?.granted, euros(500))
        XCTAssertTrue(credits.complete)
    }

    /// A missing granted amount is unknown, never the remaining one.
    func testAMissingGrantedAmountIsUnknown() throws {
        let promo = #"[{"id":"g","remaining":{"money":{"amount_minor":400,"currency":"EUR","exponent":2}},"expires_at":null},"# + tranche(id: "odd", currency: "EUR").replacingOccurrences(of: #""granted":{"money":{"amount_minor":500,"currency":"EUR""#, with: #""granted":{"money":{"amount_minor":500,"currency":"USD""#) + "]"
        let credits = try XCTUnwrap(ClaudeProviderAdapter.usageCredits(fromBody: body(promo: promo), fetchedAt: t0))
        XCTAssertEqual(credits.grants.map(\.id).sorted(), ["g", "odd"])
        XCTAssertTrue(credits.grants.allSatisfy { $0.granted == nil }, "missing, or in another currency")
        XCTAssertTrue(credits.complete)
    }

    func testGrantsAreSortedBySoonestExpiryWithNeverExpiringLast() throws {
        let promo = "[\(tranche(id: "late", expires: "2027-01-01T00:00:00Z")),\(tranche(id: "soon", expires: "2026-11-01T00:00:00Z"))]"
        let purchased = "[\(tranche(id: "forever", expires: nil))]"
        let credits = try XCTUnwrap(ClaudeProviderAdapter.usageCredits(fromBody: body(promo: promo, purchased: purchased), fetchedAt: t0))
        XCTAssertEqual(credits.grants.map(\.id), ["soon", "late", "forever"])
    }

    func testGrantInAnotherCurrencyIsSkippedAndMarksIncomplete() throws {
        let promo = "[\(tranche(id: "usd", currency: "USD")),\(tranche(id: "eur"))]"
        let credits = try XCTUnwrap(ClaudeProviderAdapter.usageCredits(fromBody: body(promo: promo), fetchedAt: t0))
        XCTAssertEqual(credits.grants.map(\.id), ["eur"])
        XCTAssertFalse(credits.complete)
    }

    func testGrantWithAnUnreadableExpiryIsSkippedAndMarksIncomplete() throws {
        let promo = "[\(tranche(id: "bad", expires: "next spring")),\(tranche(id: "good"))]"
        let credits = try XCTUnwrap(ClaudeProviderAdapter.usageCredits(fromBody: body(promo: promo), fetchedAt: t0))
        XCTAssertEqual(credits.grants.map(\.id), ["good"])
        XCTAssertFalse(credits.complete)
    }

    func testGrantWithoutIdOrAmountIsSkippedAndMarksIncomplete() throws {
        let promo = #"[{"remaining":{"money":{"amount_minor":5,"currency":"EUR","exponent":2}}},{"id":"x"},42,"# + tranche(id: "good") + "]"
        let credits = try XCTUnwrap(ClaudeProviderAdapter.usageCredits(fromBody: body(promo: promo), fetchedAt: t0))
        XCTAssertEqual(credits.grants.map(\.id), ["good"])
        XCTAssertFalse(credits.complete)
    }

    func testSpentGrantIsDroppedAndTheReadingStaysComplete() throws {
        let promo = "[\(tranche(id: "spent", remaining: 0))]"
        let credits = try XCTUnwrap(ClaudeProviderAdapter.usageCredits(fromBody: body(promo: promo), fetchedAt: t0))
        XCTAssertEqual(credits.grants, [])
        XCTAssertTrue(credits.complete, "a used-up grant is well-formed, not malformed")
    }

    func testAListOfTheWrongShapeKeepsTheBalanceButIsIncomplete() throws {
        let credits = try XCTUnwrap(ClaudeProviderAdapter.usageCredits(fromBody: body(promo: "[\(tranche(id: "good"))]", purchased: "7"), fetchedAt: t0))
        XCTAssertEqual(credits.balance, euros(1000))
        XCTAssertEqual(credits.grants.map(\.id), ["good"])
        XCTAssertFalse(credits.complete)
    }

    func testMissingOrNullListsAreEmptyAndComplete() throws {
        let json = #"{"balance":{"money":{"amount_minor":0,"currency":"EUR","exponent":2}},"tranches":null}"#
        let credits = try XCTUnwrap(ClaudeProviderAdapter.usageCredits(fromBody: json, fetchedAt: t0))
        XCTAssertEqual(credits.balance, euros(0))
        XCTAssertEqual(credits.grants, [])
        XCTAssertTrue(credits.complete)
    }

    func testNoValidBalanceMeansNoReading() {
        XCTAssertNil(ClaudeProviderAdapter.usageCredits(fromBody: #"{"promo_tranches":[]}"#, fetchedAt: t0))
        XCTAssertNil(ClaudeProviderAdapter.usageCredits(fromBody: #"{"balance":{"money":null}}"#, fetchedAt: t0))
        XCTAssertNil(ClaudeProviderAdapter.usageCredits(fromBody: #"{"balance":{"money":{"amount_minor":-1,"currency":"EUR","exponent":2}}}"#, fetchedAt: t0))
        XCTAssertNil(ClaudeProviderAdapter.usageCredits(fromBody: #"{"balance":{"money":{"amount_minor":1,"currency":"EUR","exponent":7}}}"#, fetchedAt: t0))
        XCTAssertNil(ClaudeProviderAdapter.usageCredits(fromBody: "<html>", fetchedAt: t0))
        XCTAssertNil(ClaudeProviderAdapter.usageCredits(fromBody: "[]", fetchedAt: t0))
    }

    // MARK: The switch, from the usage payload

    private func usage(_ extra: String) throws -> ClaudeUsagePayload {
        let json = #"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":20,"resets_at":null}"# + extra + "}"
        return try JSONDecoder().decode(ClaudeUsagePayload.self, from: Data(json.utf8))
    }

    func testSwitchPrefersSpendThenExtraUsage() throws {
        XCTAssertEqual(ClaudeProviderAdapter.usageCreditsEnabled(from: try usage(#","spend":{"enabled":true},"extra_usage":{"is_enabled":false}"#)), true)
        XCTAssertEqual(ClaudeProviderAdapter.usageCreditsEnabled(from: try usage(#","extra_usage":{"is_enabled":false,"user_disabled":true}"#)), false)
        XCTAssertEqual(ClaudeProviderAdapter.usageCreditsEnabled(from: try usage(#","spend":{"enabled":null},"extra_usage":{"is_enabled":true}"#)), true)
        XCTAssertEqual(ClaudeProviderAdapter.usageCreditsEnabled(from: try usage(#","spend":"oops","extra_usage":{"is_enabled":false}"#)), false)
        XCTAssertNil(ClaudeProviderAdapter.usageCreditsEnabled(from: try usage("")))
        XCTAssertNil(ClaudeProviderAdapter.usageCreditsEnabled(from: try usage(#","spend":[],"extra_usage":7"#)))
    }

    // MARK: Through the adapter

    private let usageBody = #"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":20,"resets_at":null},"spend":{"enabled":false}}"#

    func testFetchUsageCarriesTheSwitchAndNeverTheBalance() async throws {
        let org = UUID().uuidString.lowercased()
        let client = WebUsageClient { script, arguments, _ in
            if script.contains("lastActiveOrg") { return org }
            if let path = arguments["path"] as? String {
                if path == "/api/organizations" { return ["status": 200, "retryAfter": NSNull(), "body": "[]"] }
                return ["status": 200, "retryAfter": NSNull(), "body": self.usageBody]
            }
            return NSNull()
        }
        let adapter = ClaudeProviderAdapter(client: client, now: { self.t0 }, prepareWebView: { _ in })
        let snapshot = try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
        XCTAssertEqual(snapshot.usageCreditsEnabled, false)
        XCTAssertNil(snapshot.usageCredits, "the balance comes from its own read only")
    }

    func testABrokenSwitchNeverFailsUsage() async throws {
        let org = UUID().uuidString.lowercased()
        let body = #"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":20,"resets_at":null},"spend":42,"extra_usage":"x"}"#
        let client = WebUsageClient { script, arguments, _ in
            if script.contains("lastActiveOrg") { return org }
            if arguments["path"] is String { return ["status": 200, "retryAfter": NSNull(), "body": body] }
            return NSNull()
        }
        let adapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })
        let snapshot = try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
        XCTAssertNotNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.usageCreditsEnabled)
    }

    private func snapshot(org: String?) -> UsageSnapshot {
        UsageSnapshot(accountID: UUID(), fetchedAt: t0, fiveHour: nil, weekly: nil, organizationID: org)
    }

    func testFetchUsageCreditsRequestsTheOrgsPrepaidCredits() async throws {
        var requested: [String] = []
        let client = WebUsageClient { _, arguments, _ in
            if let path = arguments["path"] as? String {
                requested.append(path)
                return ["status": 200, "retryAfter": NSNull(), "body": self.verified]
            }
            return NSNull()
        }
        let adapter = ClaudeProviderAdapter(client: client, now: { self.t0.addingTimeInterval(3) }, prepareWebView: { _ in })
        let credits = try await adapter.fetchUsageCredits(for: snapshot(org: "org-1"), in: WKWebView())
        XCTAssertEqual(requested, ["/api/organizations/org-1/prepaid/credits"])
        XCTAssertEqual(credits?.balance, euros(1000))
        XCTAssertEqual(credits?.fetchedAt, t0.addingTimeInterval(3), "the read's own time, not the snapshot's")
    }

    func testFetchUsageCreditsWithoutAnOrganizationMakesNoRequest() async throws {
        var calls = 0
        let client = WebUsageClient { _, _, _ in calls += 1; return NSNull() }
        let adapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })
        let credits = try await adapter.fetchUsageCredits(for: snapshot(org: nil), in: WKWebView())
        XCTAssertNil(credits)
        XCTAssertEqual(calls, 0)
    }

    func testFetchUsageCreditsTurnsFailuresIntoNoReading() async throws {
        for (status, body) in [(403, #"{"type":"error"}"#), (404, ""), (500, "oops"), (200, "<html>"), (429, "")] {
            let client = WebUsageClient { _, arguments, _ in
                if arguments["path"] is String { return ["status": status, "retryAfter": NSNull(), "body": body] }
                return NSNull()
            }
            let adapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })
            let credits = try await adapter.fetchUsageCredits(for: snapshot(org: "org-1"), in: WKWebView())
            XCTAssertNil(credits, "status \(status)")
        }
    }

    func testFetchUsageCreditsLetsATimeoutThrough() async throws {
        let client = WebUsageClient { _, _, _ in throw WebUsageClientError.timedOut }
        let adapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })
        do {
            _ = try await adapter.fetchUsageCredits(for: snapshot(org: "org-1"), in: WKWebView())
            XCTFail("a timeout must reach the caller's recovery")
        } catch let error as WebUsageClientError {
            XCTAssertEqual(error, .timedOut)
        }
    }
}
