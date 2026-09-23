import WebKit
import XCTest
@testable import Ration

@MainActor
final class ChatGPTResetCreditsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let usageBody = #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_at":1790010000},"secondary_window":{"used_percent":20,"limit_window_seconds":604800,"reset_at":1790500000}}}"#
    private let creditsBody = #"{"credits":[{"id":"credit-1","status":"available","expires_at":"2026-10-22T20:27:51.048833Z","title":"Full reset","is_supported_by_plan":true},{"id":"credit-2","status":"available","expires_at":"2026-10-22T20:27:51Z","is_supported_by_plan":false},{"id":"credit-3","status":"available","expires_at":"2026-10-22T20:27:51Z"},{"id":"credit-4","status":"redeemed","expires_at":"2026-10-22T20:27:51Z","is_supported_by_plan":true}],"available_count":3}"#

    private func adapter(resetCredits: Any) -> ChatGPTProviderAdapter {
        let usage = usageBody
        let client = WebUsageClient { _, _, _ in
            ["status": 200, "retryAfter": NSNull(), "body": usage, "resetCredits": resetCredits]
        }
        return ChatGPTProviderAdapter(client: client, now: { self.t0 }, prepareWebView: { _ in })
    }

    /// `usableNow` comes from each credit's own `is_supported_by_plan` —
    /// verified live 2026-09-23 against chatgpt.com's own bundle: the Codex
    /// "Use reset" button is disabled only by that flag (or a pending
    /// redeem). The aggregate `applicable_available_count` on `wham/usage`
    /// is never read by their UI and must not drive ours.
    func testReadsAvailableCreditsAndUsability() async throws {
        let snap = try await adapter(resetCredits: ["status": 200, "body": creditsBody]).fetchUsage(accountID: UUID(), in: WKWebView())
        let list = try XCTUnwrap(snap.resetCredits)
        XCTAssertEqual(list.fetchedAt, snap.fetchedAt)
        XCTAssertEqual(list.items.map(\.id), ["credit-1", "credit-2", "credit-3"], "only status == available")
        XCTAssertEqual(list.items.first?.count, 1)
        XCTAssertEqual(list.items.first?.title, "Full reset")
        XCTAssertEqual(
            list.items.map(\.usableNow), [true, false, nil],
            "is_supported_by_plan true / false / absent → true / false / nil"
        )
        XCTAssertTrue(list.complete)
    }

    func testNullResetEnvelopeMeansNotRead() async throws {
        let snap = try await adapter(resetCredits: NSNull()).fetchUsage(accountID: UUID(), in: WKWebView())
        XCTAssertNotNil(snap.weekly)
        XCTAssertNil(snap.resetCredits)
    }

    func testNon2xxOrBadJSONMeansNotReadAndUsageSurvives() async throws {
        for bad: Any in [["status": 500, "body": ""], ["status": 500, "body": creditsBody], ["status": 200, "body": "not json"], ["status": 200, "body": #"{"credits":7}"#], "garbage"] {
            let snap = try await adapter(resetCredits: bad).fetchUsage(accountID: UUID(), in: WKWebView())
            XCTAssertNotNil(snap.weekly)
            XCTAssertNil(snap.resetCredits, "\(bad)")
        }
    }

    func testMalformedCreditMarksIncomplete() async throws {
        let body = #"{"credits":[{"id":"credit-1","status":"available","expires_at":"2026-10-22T20:27:51Z"},{"status":"available"}]}"#
        let snap = try await adapter(resetCredits: ["status": 200, "body": body]).fetchUsage(accountID: UUID(), in: WKWebView())
        XCTAssertEqual(snap.resetCredits?.items.map(\.id), ["credit-1"])
        XCTAssertEqual(snap.resetCredits?.complete, false)
    }

    func testScriptBoundsTheResetFetch() {
        let script = WebUsageClient.chatGPTFetchScriptForTesting
        XCTAssertTrue(script.contains("/backend-api/wham/rate-limit-reset-credits"))
        XCTAssertTrue(script.contains("AbortController"))
        XCTAssertTrue(script.contains("10000"))
        XCTAssertTrue(script.contains("resetCredits"))
    }

    /// A fixed 10s abort timer on the reset fetch,
    /// stacked on top of a slow session+usage read, can push the WHOLE
    /// evaluation past `WebUsageClient.evaluationTimeout` (60s) — which
    /// discards the already-successful usage read too, not just the reset
    /// read. The script must instead spend only whatever's left of a
    /// bounded budget, and skip the reset fetch entirely once there's
    /// too little budget left to be worth attempting.
    func testScriptBoundsTheResetFetchWithinTheOverallEvaluationBudget() {
        let script = WebUsageClient.chatGPTFetchScriptForTesting
        XCTAssertTrue(script.contains("Date.now() - __started"), "measures elapsed time since entering the script")
        XCTAssertTrue(script.contains("Math.min(10000"), "caps the abort timer at 10s but shortens it under time pressure")
        XCTAssertTrue(script.contains("remaining < 1000"), "skips the reset fetch entirely once under 1s of budget remains")
    }
}
