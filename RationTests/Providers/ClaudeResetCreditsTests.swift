import WebKit
import XCTest
@testable import Ration

@MainActor
final class ClaudeResetCreditsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func payload(_ cedar: String) throws -> ClaudeUsagePayload {
        let json = #"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":20,"resets_at":null},"cedar_ember":"# + cedar + "}"
        return try JSONDecoder().decode(ClaudeUsagePayload.self, from: Data(json.utf8))
    }

    private let grant = #"{"id":"grant-1","label":"Launch reset","resets_total":1,"resets_left":1,"starts_at":"2026-09-22T16:00:00+00:00","ends_at":"2026-10-22T16:00:00+00:00","usable_now":true}"#

    func testDecodesGrant() throws {
        let list = try XCTUnwrap(ClaudeProviderAdapter.resetCredits(from: payload(#"{"grants":["# + grant + "]}"), fetchedAt: t0))
        XCTAssertEqual(list.fetchedAt, t0)
        XCTAssertTrue(list.complete)
        let item = try XCTUnwrap(list.items.first)
        XCTAssertEqual(item.id, "grant-1")
        XCTAssertEqual(item.title, "Launch reset")
        XCTAssertEqual(item.count, 1)
        XCTAssertEqual(item.usableNow, true)
        XCTAssertEqual(item.expiresAt, ISO8601DateFormatter().date(from: "2026-10-22T16:00:00Z"))
    }

    func testZeroResetsLeftIsDropped() throws {
        let used = grant.replacingOccurrences(of: #""resets_left":1"#, with: #""resets_left":0"#)
        let list = try XCTUnwrap(ClaudeProviderAdapter.resetCredits(from: payload(#"{"grants":["# + used + "]}"), fetchedAt: t0))
        XCTAssertEqual(list.items, [])
        XCTAssertTrue(list.complete, "a used-up grant is well-formed, not malformed")
    }

    func testMalformedGrantIsSkippedAndMarksIncomplete() throws {
        let list = try XCTUnwrap(ClaudeProviderAdapter.resetCredits(from: payload(#"{"grants":[{"id":"bad"},"# + grant + "]}"), fetchedAt: t0))
        XCTAssertEqual(list.items.map(\.id), ["grant-1"])
        XCTAssertFalse(list.complete)
    }

    func testEmptyGrantsIsAuthoritativeEmpty() throws {
        let list = try XCTUnwrap(ClaudeProviderAdapter.resetCredits(from: payload(#"{"grants":[]}"#), fetchedAt: t0))
        XCTAssertEqual(list.items, [])
        XCTAssertTrue(list.complete)
    }

    func testNullOrMissingCedarEmberIsNotRead() throws {
        XCTAssertNil(ClaudeProviderAdapter.resetCredits(from: try payload("null"), fetchedAt: t0))
        XCTAssertNil(ClaudeProviderAdapter.resetCredits(from: try payload(#""oops""#), fetchedAt: t0))
        XCTAssertNil(ClaudeProviderAdapter.resetCredits(from: try payload(#"{"eligible":false}"#), fetchedAt: t0))
    }

    func testFetchUsageRequestsCedarEmberAndCarriesOneTimestamp() async throws {
        let org = UUID().uuidString.lowercased()
        var requestedPath: String?
        let body = #"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":20,"resets_at":null},"cedar_ember":{"grants":["# + grant + "]}}"
        let client = WebUsageClient { script, arguments, _ in
            if script.contains("lastActiveOrg") { return org }
            if let path = arguments["path"] as? String {
                if path == "/api/organizations" {
                    return ["status": 200, "retryAfter": NSNull(), "body": "[]"]
                }
                requestedPath = path
                return ["status": 200, "retryAfter": NSNull(), "body": body]
            }
            return NSNull()
        }
        let adapter = ClaudeProviderAdapter(client: client, now: { self.t0 }, prepareWebView: { _ in })
        let snapshot = try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
        XCTAssertEqual(requestedPath, "/api/organizations/\(org)/usage?cedar_ember=1")
        XCTAssertEqual(snapshot.resetCredits?.fetchedAt, snapshot.fetchedAt)
        XCTAssertEqual(snapshot.resetCredits?.items.map(\.id), ["grant-1"])
    }

    func testBrokenCedarEmberNeverFailsUsage() async throws {
        let org = UUID().uuidString.lowercased()
        let body = #"{"five_hour":{"utilization":10,"resets_at":null},"seven_day":{"utilization":20,"resets_at":null},"cedar_ember":{"grants":42}}"#
        let client = WebUsageClient { script, arguments, _ in
            if script.contains("lastActiveOrg") { return org }
            if arguments["path"] is String { return ["status": 200, "retryAfter": NSNull(), "body": body] }
            return NSNull()
        }
        let adapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })
        let snapshot = try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
        XCTAssertNotNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.resetCredits)
    }
}
