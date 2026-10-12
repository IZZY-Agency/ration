import WebKit
import XCTest
@testable import Ration

/// The adapter puts the session identity the usage fetch returned on that
/// same snapshot. Any identity problem leaves it nil and never fails the
/// usage read.
@MainActor
final class ChatGPTIdentityReadTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let usageBody = #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_at":1790010000},"secondary_window":{"used_percent":20,"limit_window_seconds":604800,"reset_at":1790500000}},"plan_type":"pro"}"#

    /// `identity` is what the fetch script returned under `identity`;
    /// `.none` leaves the key out altogether.
    private func adapter(identity: Any?, status: Int = 200) -> ChatGPTProviderAdapter {
        let usage = usageBody
        let client = WebUsageClient { _, _, _ in
            var result: [String: Any] = ["status": status, "retryAfter": NSNull(), "body": status == 200 ? usage : "", "resetCredits": NSNull()]
            if let identity { result["identity"] = identity }
            return result
        }
        return ChatGPTProviderAdapter(client: client, now: { self.t0 }, prepareWebView: { _ in })
    }

    private func snapshot(identity: Any?) async throws -> UsageSnapshot {
        try await adapter(identity: identity).fetchUsage(accountID: UUID(), in: WKWebView())
    }

    func testTheIdentityLandsOnTheSnapshot() async throws {
        let snap = try await snapshot(identity: ["accountID": "acct-A", "userID": "user-1", "email": "a@b", "planType": "pro"])
        XCTAssertEqual(snap.chatGPTIdentity, ChatGPTIdentity(accountID: "acct-A", userID: "user-1", email: "a@b", planType: "pro"))
        XCTAssertNotNil(snap.weekly)
        XCTAssertEqual(snap.fetchedAt, t0)
    }

    /// Email and plan are display only: missing, null, empty or not text
    /// reads as nil and the ids still make the identity.
    func testEmailAndPlanAreOptional() async throws {
        for identity: [String: Any] in [
            ["accountID": "acct-A", "userID": "user-1"],
            ["accountID": "acct-A", "userID": "user-1", "email": NSNull(), "planType": NSNull()],
            ["accountID": "acct-A", "userID": "user-1", "email": "", "planType": ""],
            ["accountID": "acct-A", "userID": "user-1", "email": 7, "planType": ["pro"]],
        ] {
            let snap = try await snapshot(identity: identity)
            XCTAssertEqual(snap.chatGPTIdentity, ChatGPTIdentity(accountID: "acct-A", userID: "user-1", email: nil, planType: nil), "\(identity)")
        }
    }

    func testNoIdentityLeavesItNilAndUsageSurvives() async throws {
        let cases: [Any?] = [
            nil,
            NSNull(),
            "acct-A|user-1",
            7,
            [String: Any](),
            ["accountID": "acct-A"],
            ["userID": "user-1"],
            ["accountID": "", "userID": "user-1"],
            ["accountID": "acct-A", "userID": ""],
            ["accountID": 7, "userID": "user-1"],
            ["accountID": "acct-A", "userID": NSNull()],
            [["accountID": "acct-A", "userID": "user-1"]],
        ]
        for identity in cases {
            let snap = try await snapshot(identity: identity)
            XCTAssertNil(snap.chatGPTIdentity, "\(String(describing: identity))")
            XCTAssertNotNil(snap.weekly, "usage survives: \(String(describing: identity))")
            XCTAssertNotNil(snap.fiveHour)
        }
    }

    /// An identity never turns a failed usage read into a snapshot.
    func testAnIdentityNeverRescuesAFailedUsageRead() async throws {
        let adapter = adapter(identity: ["accountID": "acct-A", "userID": "user-1"], status: 401)
        do {
            _ = try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
            XCTFail("expected authenticationRequired")
        } catch {
            XCTAssertEqual(error as? ProviderError, .authenticationRequired)
        }
    }
}
