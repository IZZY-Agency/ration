import Foundation
import WebKit
import XCTest
@testable import Ration

final class ProviderAdapterTests: XCTestCase {
    /// Every shipped provider has a live adapter, in the display order the
    /// app relies on.
    @MainActor
    func testLiveProviderAdaptersAreClaudeChatGPTAndCursorInOrder() {
        XCTAssertEqual(
            LiveProviderAdapters.all.map(\.provider),
            [.claude, .chatGPT, .cursor]
        )
    }

    func testSuccessfulEnvelopeReturnsBody() throws {
        let envelope = WebResponseEnvelope(
            status: 200,
            retryAfter: nil,
            body: "{\"usage\":{}}"
        )

        XCTAssertEqual(
            try ProviderResponseValidator.body(from: envelope, now: .distantPast),
            envelope.body
        )
    }

    func testAuthenticationStatusesRequireSignIn() {
        for status in [401, 403] {
            let envelope = WebResponseEnvelope(status: status, retryAfter: nil, body: "")

            XCTAssertThrowsError(
                try ProviderResponseValidator.body(from: envelope, now: .distantPast)
            ) { error in
                XCTAssertEqual(error as? ProviderError, .authenticationRequired)
            }
        }
    }

    func testRateLimitUsesRetryAfterSeconds() {
        let now = Date(timeIntervalSince1970: 1_000)
        let envelope = WebResponseEnvelope(status: 429, retryAfter: "120", body: "")

        XCTAssertThrowsError(
            try ProviderResponseValidator.body(from: envelope, now: now)
        ) { error in
            XCTAssertEqual(
                error as? ProviderError,
                .rateLimited(retryAt: Date(timeIntervalSince1970: 1_120))
            )
        }
    }

    func testRateLimitUsesRetryAfterHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_000)
        // Wed, 21 Oct 2015 07:28:00 GMT == 1_445_412_480 since 1970.
        let envelope = WebResponseEnvelope(
            status: 429,
            retryAfter: "Wed, 21 Oct 2015 07:28:00 GMT",
            body: ""
        )

        XCTAssertThrowsError(
            try ProviderResponseValidator.body(from: envelope, now: now)
        ) { error in
            XCTAssertEqual(
                error as? ProviderError,
                .rateLimited(retryAt: Date(timeIntervalSince1970: 1_445_412_480))
            )
        }
    }

    func testRateLimitWithUnparseableRetryAfterHasNoRetryDate() {
        let envelope = WebResponseEnvelope(status: 429, retryAfter: "soon", body: "")

        XCTAssertThrowsError(
            try ProviderResponseValidator.body(from: envelope, now: .distantPast)
        ) { error in
            XCTAssertEqual(error as? ProviderError, .rateLimited(retryAt: nil))
        }
    }

    @MainActor
    func testRegistryKeepsLastAdapterForDuplicateProvider() throws {
        let first = StubAdapter(provider: .claude)
        let second = StubAdapter(provider: .claude)
        let registry = ProviderAdapterRegistry(adapters: [first, second])

        let resolved = try registry.adapter(for: .claude)
        XCTAssertTrue((resolved as? StubAdapter) === second)
    }

    @MainActor
    func testRegistryResolvesCursorAdapter() throws {
        let registry = ProviderAdapterRegistry(adapters: LiveProviderAdapters.all)

        let resolved = try registry.adapter(for: .cursor)
        XCTAssertEqual(resolved.provider, .cursor)
    }

    func testServerStatusPreservesStatusCodeWithoutBody() {
        let envelope = WebResponseEnvelope(status: 503, retryAfter: nil, body: "secret")

        XCTAssertThrowsError(
            try ProviderResponseValidator.body(from: envelope, now: .distantPast)
        ) { error in
            XCTAssertEqual(error as? ProviderError, .server(statusCode: 503))
        }
    }

    /// An origin-guard mismatch inside the fetch script returns status 0.
    /// That must surface as a transient server error the refresh coordinator
    /// treats as stale/unavailable — never as a successful body or a crash.
    func testOriginMismatchStatusZeroIsTransientServerError() {
        let envelope = WebResponseEnvelope(status: 0, retryAfter: nil, body: "")

        XCTAssertThrowsError(
            try ProviderResponseValidator.body(from: envelope, now: .distantPast)
        ) { error in
            XCTAssertEqual(error as? ProviderError, .server(statusCode: 0))
        }
    }
}

@MainActor
private final class StubAdapter: ProviderAdapter {
    let provider: Provider
    let signInURL = URL(string: "https://example.com/")!

    init(provider: Provider) {
        self.provider = provider
    }

    func verifySession(in webView: WKWebView) async throws {}

    func fetchUsage(
        accountID: UUID,
        in webView: WKWebView
    ) async throws -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            fetchedAt: .distantPast,
            fiveHour: nil,
            weekly: nil
        )
    }
}
