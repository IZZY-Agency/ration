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

    /// On the 1st no UTC day has finished and Anthropic refuses the range
    /// (400, live 2026-10-01): an empty month so far, with no request.
    func testTheFirstDayOfAMonthIsEmptyWithoutAsking() async throws {
        let firstDay = ISO8601DateFormatter().date(from: "2026-10-01T10:31:00Z")!
        let client = AnthropicSpendClient(http: http, now: { firstDay })
        let month = UTCMonth(containing: firstDay)
        StubURLProtocol.enqueue("/v1/organizations/me", .init(body: Data(#"{"id":"org-1","name":"Acme"}"#.utf8)))
        let cost = try await client.costReport(month: month, key: key, refreshStartedAt: firstDay)
        XCTAssertEqual(cost.monthToDateCents, 0)
        XCTAssertEqual(cost.coversToday, false, "the card says through yesterday")
        let tokens = try await client.tokenReport(month: month, key: key, refreshStartedAt: firstDay)
        XCTAssertEqual(tokens.month, month)
        XCTAssertEqual(StubURLProtocol.requests.map { $0.url?.path }, ["/v1/organizations/me"], "only the key is proved, no report asked")

        // From the 2nd, the usual request covering the 1st.
        StubURLProtocol.enqueue("/v1/organizations/cost_report", page(hasMore: false))
        let secondDay = ISO8601DateFormatter().date(from: "2026-10-02T00:00:01Z")!
        _ = try await AnthropicSpendClient(http: http, now: { secondDay }).costReport(month: month, key: key, refreshStartedAt: secondDay)
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.path, "/v1/organizations/cost_report")
    }

    /// A revoked key on the 1st is still a revoked key.
    func testTheFirstDayStillRejectsARevokedKey() async {
        let firstDay = ISO8601DateFormatter().date(from: "2026-10-01T10:31:00Z")!
        StubURLProtocol.enqueue("/v1/organizations/me", .init(status: 401, body: Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8)))
        do {
            _ = try await AnthropicSpendClient(http: http, now: { firstDay }).costReport(month: UTCMonth(containing: firstDay), key: key, refreshStartedAt: firstDay)
            XCTFail("expected keyRejected")
        } catch {
            XCTAssertEqual(error as? APISpendError, .keyRejected)
        }
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

    /// An unexpected answer is logged with the vendor's own words, never more.
    func testTheVendorErrorMessageIsReadForTheLog() {
        let anthropic = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"ending_at must be after starting_at"}}"#.utf8)
        XCTAssertEqual(APISpendHTTP.errorMessage(anthropic), "invalid_request_error: ending_at must be after starting_at")
        XCTAssertEqual(APISpendHTTP.errorMessage(Data("<html>".utf8)), "")
        let echoed = Data(#"{"error":{"type":"invalid_request_error","message":"bad key sk-ant-admin01-SENTINELSENTINEL for org 3f2a9c1e0b7d4e6fa1b2c3d4 <script>"}}"#.utf8)
        let redacted = APISpendHTTP.errorMessage(echoed)
        XCTAssertFalse(redacted.contains("SENTINEL"), redacted)
        XCTAssertFalse(redacted.contains("3f2a9c1e0b7d4e6fa1b2c3d4"), redacted)
        XCTAssertFalse(redacted.contains("<"), redacted)
        let long = "{\"error\":{\"message\":\"" + String(repeating: "x ", count: 250) + "\"}}"
        XCTAssertEqual(APISpendHTTP.errorMessage(Data(long.utf8)).count, 300)
    }
}
