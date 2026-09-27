import XCTest
@testable import Ration

final class APISpendHTTPTests: XCTestCase {
    private let sentinel = "sk-ant-admin01-SENTINELSENTINEL"
    private var http: APISpendHTTP!

    override func setUp() {
        StubURLProtocol.reset()
        http = APISpendHTTP(protocolClasses: [StubURLProtocol.self], now: { Date(timeIntervalSince1970: 1_000) })
    }

    func testBuildsHTTPSRequestToTheVendorHostWithHeaders() async throws {
        StubURLProtocol.enqueue("/v1/organizations/me", .init(body: Data("{}".utf8)))
        _ = try await http.get(vendor: .anthropic, path: "/v1/organizations/me", query: [URLQueryItem(name: "a", value: "b")], headers: ["x-api-key": sentinel])
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.scheme, "https")
        XCTAssertEqual(request.url?.host(), "api.anthropic.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), sentinel)
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "a", value: "b")])
    }

    func testStatusMapping() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertNil(APISpendHTTP.map(status: 200, headers: [:], now: now))
        XCTAssertEqual(APISpendHTTP.map(status: 401, headers: [:], now: now), .keyRejected)
        XCTAssertEqual(APISpendHTTP.map(status: 403, headers: [:], now: now), .noAdminAccess)
        XCTAssertEqual(APISpendHTTP.map(status: 429, headers: ["Retry-After": "30"], now: now), .rateLimited(retryAt: now.addingTimeInterval(30)))
        XCTAssertEqual(APISpendHTTP.map(status: 429, headers: [:], now: now), .rateLimited(retryAt: nil))
        XCTAssertEqual(APISpendHTTP.map(status: 503, headers: [:], now: now), .server(status: 503))
        XCTAssertEqual(APISpendHTTP.map(status: 302, headers: [:], now: now), .redirectRefused)
        XCTAssertEqual(APISpendHTTP.map(status: 404, headers: [:], now: now), .integrationChanged(.unexpectedStatus))
    }

    func testRedirectIsRefusedAndNeverFollowed() async {
        StubURLProtocol.enqueue("/v1/organizations/me", .init(status: 302, headers: ["Location": "https://evil.example/steal"], redirectTo: URL(string: "https://evil.example/steal")!))
        do {
            _ = try await http.get(vendor: .anthropic, path: "/v1/organizations/me", query: [], headers: ["x-api-key": sentinel])
            XCTFail("expected redirectRefused")
        } catch {
            XCTAssertEqual(error as? APISpendError, .redirectRefused)
        }
        XCTAssertFalse(StubURLProtocol.requests.contains { $0.url?.host() == "evil.example" })
    }

    /// A captive portal answers 200 with HTML.
    func testNonJSON200IsTransport() async {
        StubURLProtocol.enqueue("/v1/organizations/me", .init(headers: ["Content-Type": "text/html"], body: Data("<html>".utf8)))
        do {
            _ = try await http.get(vendor: .anthropic, path: "/v1/organizations/me", query: [], headers: [:])
            XCTFail("expected transport")
        } catch {
            XCTAssertEqual(error as? APISpendError, .transport)
        }
    }

    /// A portal page mislabelled as JSON is still "couldn't reach".
    func testHTMLBodyLabelledJSONIsTransport() async {
        StubURLProtocol.enqueue("/v1/organizations/me", .init(headers: ["Content-Type": "application/json"], body: Data("\n  <!DOCTYPE html><html>login</html>".utf8)))
        do {
            _ = try await http.get(vendor: .anthropic, path: "/v1/organizations/me", query: [], headers: [:])
            XCTFail("expected transport")
        } catch {
            XCTAssertEqual(error as? APISpendError, .transport)
        }
    }

    func testErrorsNeverCarryTheKey() async {
        StubURLProtocol.enqueue("/v1/organizations/me", .init(status: 401))
        do {
            _ = try await http.get(vendor: .anthropic, path: "/v1/organizations/me", query: [], headers: ["x-api-key": sentinel])
            XCTFail("expected keyRejected")
        } catch {
            XCTAssertEqual(error as? APISpendError, .keyRejected)
            XCTAssertFalse(String(describing: error).contains("SENTINEL"))
            XCTAssertFalse(String(reflecting: error).contains("SENTINEL"))
            XCTAssertFalse(error.localizedDescription.contains("SENTINEL"))
        }
    }
}
