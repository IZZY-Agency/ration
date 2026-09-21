import Foundation
import WebKit

@MainActor
struct CursorProviderAdapter: ProviderAdapter {
    typealias PrepareWebView = @MainActor (WKWebView) async throws -> Void

    let provider = Provider.cursor
    let signInURL = URL(string: "https://cursor.com/dashboard")!

    private let client: WebUsageClient
    private let now: @MainActor () -> Date
    private let prepareWebView: PrepareWebView

    init(
        client: WebUsageClient = WebUsageClient(),
        now: @escaping @MainActor () -> Date = { .now },
        prepareWebView: @escaping PrepareWebView = CursorWebViewPreparation.prepare
    ) {
        self.client = client
        self.now = now
        self.prepareWebView = prepareWebView
    }

    func verifySession(in webView: WKWebView) async throws {
        try await prepareWebView(webView)
        _ = try await cursorSpend(in: webView)
    }

    func fetchUsage(
        accountID: UUID,
        in webView: WKWebView
    ) async throws -> UsageSnapshot {
        try await prepareWebView(webView)
        let spend = try await cursorSpend(in: webView)

        return UsageSnapshot(
            accountID: accountID,
            fetchedAt: now(),
            fiveHour: nil,
            weekly: nil,
            cursorSpend: spend
        )
    }

    private func cursorSpend(in webView: WKWebView) async throws -> CursorSpend {
        let body = try await responseBody(in: webView)
        return try await Self.parse(body)
    }

    private func responseBody(in webView: WKWebView) async throws -> String {
        do {
            let envelope = try await client.fetchCursor(in: webView)
            return try ProviderResponseValidator.body(from: envelope, now: now())
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProviderError {
            throw error
        } catch let error as WebUsageClientError where error == .timedOut {
            // Pass the timeout through untouched — AccountSessionManager
            // recycles the web view on it; the refresh coordinator's generic
            // catch maps it to .transport afterwards.
            throw error
        } catch {
            throw ProviderError.transport
        }
    }

    /// Decode the COMPACT payload the in-page `cursorFetchScript` produces.
    /// `nonisolated async` so the decode runs OFF the main actor, mirroring
    /// the Claude/ChatGPT adapters. Absent or invalid data throws
    /// `integrationChanged` — a spend value is never fabricated.
    ///
    /// - `periodStart` / `resetsAt` are `Date(timeIntervalSince1970: ms / 1000)`
    ///   (`periodStartMs` / `periodEndMs` are milliseconds).
    /// - `spentCents` is used directly.
    /// - `integrationChanged` when: the JSON fails to decode; either period
    ///   field is not finite or `<= 0`; the start is not before the end; or
    ///   `spentCents < 0`.
    nonisolated static func parse(_ body: String) async throws -> CursorSpend {
        let payload: CursorSpendPayload
        do {
            payload = try JSONDecoder().decode(
                CursorSpendPayload.self,
                from: Data(body.utf8)
            )
        } catch {
            throw ProviderError.integrationChanged
        }

        guard payload.periodEndMs.isFinite, payload.periodEndMs > 0 else {
            throw ProviderError.integrationChanged
        }
        guard
            payload.periodStartMs.isFinite,
            payload.periodStartMs > 0,
            payload.periodStartMs < payload.periodEndMs
        else {
            throw ProviderError.integrationChanged
        }
        guard payload.spentCents >= 0 else {
            throw ProviderError.integrationChanged
        }
        // An empty `membershipType` would render as a blank plan tag. The
        // in-page script already rejects it; guard here too so the decode
        // boundary — the part under test — never yields a label-less card.
        guard !payload.membershipType.isEmpty else {
            throw ProviderError.integrationChanged
        }

        return CursorSpend(
            spentCents: payload.spentCents,
            periodStart: Date(timeIntervalSince1970: payload.periodStartMs / 1000),
            resetsAt: Date(timeIntervalSince1970: payload.periodEndMs / 1000),
            planLabel: label(for: payload.membershipType)
        )
    }

    /// Map Cursor's raw `membershipType` to a display label. Case-insensitive on
    /// the raw value; an unknown tier falls back to the raw value capitalized
    /// (first letter upper, rest as-is).
    nonisolated static func label(for membershipType: String) -> String {
        switch membershipType.lowercased() {
        case "pro":
            return "Pro"
        case "pro_plus", "pro-plus":
            return "Pro+"
        case "ultra":
            return "Ultra"
        case "free":
            return "Free"
        default:
            guard let first = membershipType.first else { return membershipType }
            return first.uppercased() + String(membershipType.dropFirst())
        }
    }
}

/// The compact payload emitted by `WebUsageClient.cursorFetchScript`.
/// `periodStartMs`, `periodEndMs` and `spentCents` are required (a missing
/// field is a changed integration → decode fails → `integrationChanged`);
/// `isYearlyPlan` is decoded for contract fidelity but not load-bearing for
/// `CursorSpend`.
private struct CursorSpendPayload: Decodable, Sendable {
    let membershipType: String
    let isYearlyPlan: Bool?
    let periodStartMs: Double
    let periodEndMs: Double
    let spentCents: Int
}

enum CursorUsagePage {
    private static let exactHost = "cursor.com"
    private static let exactPath = "/dashboard"

    static func isReady(url: URL?, isLoading: Bool) -> Bool {
        guard !isLoading, let url else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host()?.lowercased() == exactHost
            && (url.port == nil || url.port == 443)
            && url.path == exactPath
    }
}

@MainActor
private enum CursorWebViewPreparation {
    private static let dashboardURL = URL(
        string: "https://cursor.com/dashboard"
    )!

    static func prepare(_ webView: WKWebView) async throws {
        if CursorUsagePage.isReady(url: webView.url, isLoading: webView.isLoading) {
            return
        }

        webView.load(URLRequest(url: dashboardURL))

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            try Task.checkCancellation()
            if CursorUsagePage.isReady(
                url: webView.url,
                isLoading: webView.isLoading
            ) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw ProviderError.transport
    }
}
