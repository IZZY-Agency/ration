import XCTest
@testable import Ration

final class APISpendClientTests: XCTestCase {
    private let key = "sk-ant-admin01-SENTINELSENTINEL"
    private let now = ISO8601DateFormatter().date(from: "2026-09-27T17:05:00Z")!
    private var http: APISpendHTTP!

    override func setUp() {
        StubURLProtocol.reset()
        http = APISpendHTTP(protocolClasses: [StubURLProtocol.self])
    }

    private func clock() -> @Sendable () -> Date { let now = self.now; return { now } }

    private func page(hasMore: Bool) -> StubURLProtocol.Reply {
        .init(body: Data(#"{"data":[],"has_more":\#(hasMore),"next_page":\#(hasMore ? "\"next\"" : "null")}"#.utf8))
    }

    func testAnthropicCostRequestShapeAndHeaders() async throws {
        StubURLProtocol.enqueue("/v1/organizations/cost_report", page(hasMore: false))
        let client = AnthropicSpendClient(http: http, now: clock())
        _ = try await client.costReport(month: UTCMonth(containing: now), key: key, refreshStartedAt: now)
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(items.contains(URLQueryItem(name: "starting_at", value: "2026-09-01T00:00:00Z")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "ending_at", value: "2026-09-28T00:00:00Z")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "bucket_width", value: "1d")))
        XCTAssertTrue(items.contains(URLQueryItem(name: "group_by[]", value: "description")))
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), key)
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
    }

    func testPaginationFollowsNextPageAndCapsAtTen() async {
        for _ in 0..<11 { StubURLProtocol.enqueue("/v1/organizations/cost_report", page(hasMore: true)) }
        let client = AnthropicSpendClient(http: http, now: clock())
        do {
            _ = try await client.costReport(month: UTCMonth(containing: now), key: key, refreshStartedAt: now)
            XCTFail("expected pageCap")
        } catch {
            XCTAssertEqual(error as? APISpendError, .integrationChanged(.pageCap))
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 10)
        XCTAssertEqual(URLComponents(url: StubURLProtocol.requests[1].url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "page" }?.value, "next")
    }

    /// `has_more: true` without a token is NOT a complete report.
    func testHasMoreWithoutATokenIsRejectedNotTruncated() async {
        let broken = StubURLProtocol.Reply(body: Data(#"{"data":[],"has_more":true,"next_page":null}"#.utf8))
        StubURLProtocol.enqueue("/v1/organizations/cost_report", broken)
        let client = AnthropicSpendClient(http: http, now: clock())
        do {
            _ = try await client.costReport(month: UTCMonth(containing: now), key: key, refreshStartedAt: now)
            XCTFail("expected integrationChanged")
        } catch {
            XCTAssertEqual(error as? APISpendError, .integrationChanged(.decode))
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    /// An org paused or removed mid-report stops paging — no further
    /// request goes out with its key.
    func testPagingStopsWhenTheFetchIsNoLongerWanted() async {
        for _ in 0..<3 { StubURLProtocol.enqueue("/v1/organizations/cost_report", page(hasMore: true)) }
        let client = AnthropicSpendClient(http: http, now: clock())
        do {
            // Wanted until the first page has gone out (then paused/removed).
            _ = try await APISpendFetchScope.$isStillWanted.withValue({ @Sendable in StubURLProtocol.requests.count < 1 }) {
                try await client.costReport(month: UTCMonth(containing: self.now), key: self.key, refreshStartedAt: self.now)
            }
            XCTFail("expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 1)
    }

    func testAnthropicIdentityFromMe() async throws {
        StubURLProtocol.enqueue("/v1/organizations/me", .init(body: Data(#"{"type":"organization","id":"org-1","name":"IZZY"}"#.utf8)))
        let identity = try await AnthropicSpendClient(http: http, now: clock()).identity(key: key)
        XCTAssertEqual(identity, OrgIdentity(id: "org-1", name: "IZZY"))
    }

    func testOpenAIUsesBearerAndReadsTheOrganizationHeader() async throws {
        StubURLProtocol.enqueue("/v1/organization/costs", .init(headers: ["Content-Type": "application/json", "openai-organization": "org-abc"], body: Data(#"{"object":"page","data":[],"has_more":false,"next_page":null}"#.utf8)))
        let client = OpenAISpendClient(http: http, now: clock())
        let identity = try await client.identity(key: "sk-admin-SENTINELSENTINEL")
        XCTAssertEqual(identity, OrgIdentity(id: "org-abc", name: nil))
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-admin-SENTINELSENTINEL")
        let limits = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.filter { $0.name == "limit" }
        XCTAssertEqual(limits, [URLQueryItem(name: "limit", value: "1")])
    }

    func testOpenAIWithoutTheHeaderHasNoIdentity() async throws {
        StubURLProtocol.enqueue("/v1/organization/costs", .init(body: Data(#"{"object":"page","data":[],"has_more":false,"next_page":null}"#.utf8)))
        let identity = try await OpenAISpendClient(http: http, now: clock()).identity(key: "sk-admin-SENTINELSENTINEL")
        XCTAssertNil(identity)
    }

    func testOpenAICostQueryUsesUnixSecondsAndLineItems() async throws {
        StubURLProtocol.enqueue("/v1/organization/costs", .init(body: Data(#"{"object":"page","data":[],"has_more":false,"next_page":null}"#.utf8)))
        _ = try await OpenAISpendClient(http: http, now: clock()).costReport(month: UTCMonth(containing: now), key: "sk-admin-SENTINELSENTINEL", refreshStartedAt: now)
        let items = URLComponents(url: StubURLProtocol.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertTrue(items.contains(URLQueryItem(name: "start_time", value: "1788220800")))   // 2026-09-01T00:00:00Z
        XCTAssertTrue(items.contains(URLQueryItem(name: "end_time", value: "1790553600")))     // 2026-09-28T00:00:00Z
        XCTAssertTrue(items.contains(URLQueryItem(name: "group_by", value: "line_item")))
    }

    func testEndParameterDefaultsToTomorrowCappedAtMonthEnd() {
        let month = UTCMonth(containing: now)
        XCTAssertEqual(APISpendEndpoints.endParameter(for: month, now: now), ISO8601DateFormatter().date(from: "2026-09-28T00:00:00Z"))
        let lastDay = ISO8601DateFormatter().date(from: "2026-09-30T20:00:00Z")!
        XCTAssertEqual(APISpendEndpoints.endParameter(for: month, now: lastDay), month.nextStart)
    }
}
