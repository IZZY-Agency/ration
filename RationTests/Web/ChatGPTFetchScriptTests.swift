import WebKit
import XCTest
@testable import Ration

/// Runs the REAL `WebUsageClient.chatGPTFetchScript` body with a stubbed
/// `fetch`, so what it returns — the usage envelope and the session identity
/// beside it — is pinned at the JS level.
///
/// The page is an empty document given the base URL `https://chatgpt.com/`
/// (`loadHTMLString`: nothing is requested), so the script's own origin gate
/// passes unchanged; the data store is non-persistent, so no real cookie is
/// in reach. The stubs go into `.defaultClient`, the content world production
/// runs in, in a separate evaluation: the script under test is byte-for-byte
/// the production one.
@MainActor
final class ChatGPTFetchScriptTests: XCTestCase {
    private var webView: WKWebView!
    private var loader: PageLoader!

    private static let usageBody = #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_at":1790010000},"secondary_window":{"used_percent":20,"limit_window_seconds":604800,"reset_at":1790500000}}}"#
    private static let session = #"{"accessToken":"t","user":{"id":"user-1","email":"a@b"},"account":{"id":"acct-A","planType":"pro"}}"#

    override func setUp() async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.isFraudulentWebsiteWarningEnabled = false
        webView = WKWebView(frame: .zero, configuration: configuration)
        loader = PageLoader()
        webView.navigationDelegate = loader
        try await loader.load("<!doctype html><title>stub</title>", baseURL: URL(string: "https://chatgpt.com/")!, in: webView)
    }

    override func tearDown() async throws {
        webView = nil
        loader = nil
    }

    // MARK: - Harness

    private struct Outcome {
        let result: [String: Any]?
        /// Every request the script made: `path` and the `headers` it sent.
        let requests: [[String: Any]]

        var status: Int? { (result?["status"] as? NSNumber)?.intValue }
        var body: String? { result?["body"] as? String }
        /// The script's raw `identity` value; nil when the key is absent.
        var identity: Any? { result?["identity"] }
        var identityObject: [String: Any]? { identity as? [String: Any] }
        var hasNoIdentity: Bool { identity == nil || identity is NSNull }

        func headers(for path: String) -> [String: Any]? {
            requests.first { $0["path"] as? String == path }?["headers"] as? [String: Any]
        }
    }

    /// Stubs `fetch` in the script's content world, then runs the production
    /// script and reads back the requests it made.
    private func run(session: String, sessionStatus: Int = 200) async throws -> Outcome {
        let stub = """
        window.__ration = { requests: [] };
        window.fetch = async function (path, init) {
            const headers = Object.assign({}, (init && init.headers) || {});
            window.__ration.requests.push({ path: String(path), headers });
            const json = { "Content-Type": "application/json" };
            if (path === "/api/auth/session") {
                return new Response(sessionBody, { status: sessionStatus, headers: json });
            }
            if (path === "/backend-api/wham/usage") {
                return new Response(usageBody, { status: 200, headers: json });
            }
            if (path === "/backend-api/wham/rate-limit-reset-credits") {
                return new Response('{"credits":[]}', { status: 200, headers: json });
            }
            return new Response("unexpected " + path, { status: 404 });
        };
        return location.origin;
        """
        let origin = try await webView.callAsyncJavaScript(
            stub,
            arguments: ["sessionBody": session, "sessionStatus": sessionStatus, "usageBody": Self.usageBody],
            in: nil,
            contentWorld: .defaultClient
        ) as? String
        XCTAssertEqual(origin, "https://chatgpt.com", "the page must pass the script's own origin gate")

        let result = try await webView.callAsyncJavaScript(
            WebUsageClient.chatGPTFetchScriptForTesting,
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        )
        let probe = try await webView.callAsyncJavaScript(
            "return window.__ration;",
            arguments: [:],
            in: nil,
            contentWorld: .defaultClient
        ) as? [String: Any]
        return Outcome(result: result as? [String: Any], requests: probe?["requests"] as? [[String: Any]] ?? [])
    }

    // MARK: - The identity rides with the usage

    func testTheScriptReturnsTheSessionIdentityBesideTheUsage() async throws {
        let outcome = try await run(session: Self.session)
        XCTAssertEqual(outcome.status, 200)
        XCTAssertEqual(outcome.body, Self.usageBody, "the usage read is unchanged")
        XCTAssertNotNil(outcome.result?["resetCredits"] as? [String: Any], "and so is the reset read")
        let identity = try XCTUnwrap(outcome.identityObject, "identity: \(String(describing: outcome.identity))")
        XCTAssertEqual(identity as NSDictionary, ["accountID": "acct-A", "userID": "user-1", "email": "a@b", "planType": "pro"] as NSDictionary)
        let usageHeaders = try XCTUnwrap(outcome.headers(for: "/backend-api/wham/usage"))
        XCTAssertEqual(usageHeaders["ChatGPT-Account-ID"] as? String, "acct-A", "the same account id authorises the usage read")
        XCTAssertEqual(usageHeaders["Authorization"] as? String, "Bearer t")
    }

    /// The whole path: the live evaluator runs the script, `fetchChatGPT`
    /// decodes what it returns.
    func testTheClientDecodesTheIdentity() async throws {
        _ = try await run(session: Self.session) // installs the stubs
        let result = try await WebUsageClient().fetchChatGPT(in: webView)
        XCTAssertEqual(result.usage.status, 200)
        XCTAssertEqual(result.identity, ChatGPTIdentity(accountID: "acct-A", userID: "user-1", email: "a@b", planType: "pro"))
    }

    func testNoIdentityWithoutBothIDsWhileTheUsageReadSucceeds() async throws {
        let sessions = [
            #"{"accessToken":"t","user":{"email":"a@b"},"account":{"id":"acct-A","planType":"pro"}}"#,
            #"{"accessToken":"t","user":{"id":"","email":"a@b"},"account":{"id":"acct-A"}}"#,
            #"{"accessToken":"t","user":{"id":42},"account":{"id":"acct-A"}}"#,
            #"{"accessToken":"t","account":{"id":"acct-A"}}"#,
            #"{"accessToken":"t","user":{"id":"user-1"},"account":{"planType":"pro"}}"#,
            #"{"accessToken":"t","user":{"id":"user-1"},"account":{"id":["acct-A"]}}"#,
            #"{"accessToken":"t","user":{"id":"user-1"}}"#,
        ]
        for session in sessions {
            let outcome = try await run(session: session)
            XCTAssertEqual(outcome.status, 200, session)
            XCTAssertEqual(outcome.body, Self.usageBody, "usage still read: \(session)")
            XCTAssertTrue(outcome.hasNoIdentity, "\(session) → \(String(describing: outcome.identity))")
        }
    }

    /// Strings only: anything else in `email` or `planType` reads as absent,
    /// and the ids alone still make an identity.
    func testOnlyStringsReachTheIdentity() async throws {
        let outcome = try await run(session: #"{"accessToken":"t","user":{"id":"user-1","email":{"accessToken":"t"}},"account":{"id":"acct-A","planType":["pro"]}}"#)
        let identity = try XCTUnwrap(outcome.identityObject)
        XCTAssertEqual(identity["accountID"] as? String, "acct-A")
        XCTAssertEqual(identity["userID"] as? String, "user-1")
        XCTAssertTrue(identity["email"] == nil || identity["email"] is NSNull, "\(String(describing: identity["email"]))")
        XCTAssertTrue(identity["planType"] == nil || identity["planType"] is NSNull, "\(String(describing: identity["planType"]))")
    }

    // MARK: - Signed out is unchanged and carries no identity

    func testASessionWithoutAnAccessTokenStillAnswers401() async throws {
        for session in [
            #"{"user":{"id":"user-1","email":"a@b"},"account":{"id":"acct-A","planType":"pro"}}"#,
            #"{"accessToken":"","user":{"id":"user-1"},"account":{"id":"acct-A"}}"#,
            "{}",
        ] {
            let outcome = try await run(session: session)
            XCTAssertEqual(outcome.status, 401, session)
            XCTAssertEqual(outcome.body, "", session)
            XCTAssertTrue(outcome.result?["retryAfter"] is NSNull, session)
            XCTAssertTrue(outcome.hasNoIdentity, "signed out → no identity: \(session)")
            XCTAssertEqual(outcome.requests.map { $0["path"] as? String }, ["/api/auth/session"], "nothing else is requested")
        }
    }

    func testAFailedSessionReadCarriesNoIdentity() async throws {
        let outcome = try await run(session: Self.session, sessionStatus: 403)
        XCTAssertEqual(outcome.status, 403)
        XCTAssertTrue(outcome.hasNoIdentity)
    }

    // MARK: - Never the token

    func testTheIdentityNeverCarriesTheAccessToken() async throws {
        let token = "eyJhbGciOiJSUzI1NiJ9.tok-SECRET-7f3a.sig"
        let outcome = try await run(session: #"{"accessToken":"\#(token)","user":{"id":"user-1","email":"a@b"},"account":{"id":"acct-A","planType":"pro"}}"#)
        let identity = try XCTUnwrap(outcome.identityObject)
        XCTAssertEqual(Set(identity.keys), ["accountID", "userID", "email", "planType"], "exactly the four fields")
        let serialized = String(decoding: try JSONSerialization.data(withJSONObject: identity), as: UTF8.self)
        XCTAssertFalse(serialized.contains("SECRET"), serialized)
        XCTAssertFalse(serialized.contains("eyJhbGci"), serialized)
        for value in identity.values {
            XCTAssertTrue(value is String, "strings only: \(value)")
        }
    }
}

/// Waits for the one `loadHTMLString` navigation to settle (bounded: a load
/// that never reports back fails the test instead of hanging it).
@MainActor
private final class PageLoader: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, any Error>?

    func load(_ html: String, baseURL: URL, in webView: WKWebView) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.finish(URLError(.timedOut))
            }
        }
    }

    private func finish(_ error: (any Error)?) {
        guard let continuation else { return }
        self.continuation = nil
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(nil)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finish(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finish(error)
    }
}
