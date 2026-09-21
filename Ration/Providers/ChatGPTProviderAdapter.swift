import Foundation
import WebKit

@MainActor
struct ChatGPTProviderAdapter: ProviderAdapter {
    typealias PrepareWebView = @MainActor (WKWebView) async throws -> Void

    let provider = Provider.chatGPT
    let signInURL = URL(string: "https://chatgpt.com/codex/settings/usage")!

    private let client: WebUsageClient
    private let now: @MainActor () -> Date
    private let prepareWebView: PrepareWebView

    init(
        client: WebUsageClient = WebUsageClient(),
        now: @escaping @MainActor () -> Date = { .now },
        prepareWebView: @escaping PrepareWebView = ChatGPTWebViewPreparation.prepare
    ) {
        self.client = client
        self.now = now
        self.prepareWebView = prepareWebView
    }

    func verifySession(in webView: WKWebView) async throws {
        try await prepareWebView(webView)
        _ = try await usageWindows(in: webView)
    }

    func fetchUsage(
        accountID: UUID,
        in webView: WKWebView
    ) async throws -> UsageSnapshot {
        try await prepareWebView(webView)
        let windows = try await usageWindows(in: webView)

        return UsageSnapshot(
            accountID: accountID,
            fetchedAt: now(),
            fiveHour: windows.fiveHour,
            weekly: windows.weekly
        )
    }

    private func usageWindows(
        in webView: WKWebView
    ) async throws -> (fiveHour: UsageWindow?, weekly: UsageWindow?) {
        let body = try await responseBody(in: webView)
        let payload: ChatGPTUsagePayload = try await decode(body)
        let primary = try usageWindow(
            from: payload.rateLimit?.primaryWindow,
            fallbackKind: .fiveHour
        )
        let secondary = try usageWindow(
            from: payload.rateLimit?.secondaryWindow,
            fallbackKind: .weekly
        )
        if let primary, let secondary, primary.kind == secondary.kind {
            throw ProviderError.integrationChanged
        }
        let fiveHour = primary?.kind == .fiveHour
            ? primary
            : secondary?.kind == .fiveHour ? secondary : nil
        let weekly = primary?.kind == .weekly
            ? primary
            : secondary?.kind == .weekly ? secondary : nil
        guard fiveHour != nil || weekly != nil else {
            throw ProviderError.integrationChanged
        }
        return (fiveHour, weekly)
    }

    private func responseBody(in webView: WKWebView) async throws -> String {
        do {
            let envelope = try await client.fetchChatGPT(in: webView)
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

    /// Off-main decode (see ClaudeProviderAdapter.decode for the rationale).
    private nonisolated func decode<Value: Decodable & Sendable>(
        _ body: String
    ) async throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(body.utf8))
        } catch {
            throw ProviderError.integrationChanged
        }
    }

    private func usageWindow(
        from payload: ChatGPTUsageWindowPayload?,
        fallbackKind: UsageWindowKind
    ) throws -> UsageWindow? {
        guard let payload else { return nil }
        guard
            let usedPercent = payload.usedPercent,
            let resetTimestamp = payload.resetAt
        else {
            return nil
        }
        guard
            usedPercent.isFinite,
            (0...100).contains(usedPercent),
            resetTimestamp.isFinite,
            resetTimestamp > 0
        else {
            throw ProviderError.integrationChanged
        }
        let kind: UsageWindowKind
        switch payload.limitWindowSeconds {
        case nil:
            kind = fallbackKind
        case 5 * 60 * 60:
            kind = .fiveHour
        case 7 * 24 * 60 * 60:
            kind = .weekly
        default:
            throw ProviderError.integrationChanged
        }

        return UsageWindow(
            kind: kind,
            remainingFraction: 1 - (usedPercent / 100),
            resetsAt: Date(timeIntervalSince1970: resetTimestamp)
        )
    }
}

private struct ChatGPTUsagePayload: Decodable, Sendable {
    let rateLimit: ChatGPTRateLimitPayload?

    enum CodingKeys: String, CodingKey {
        case rateLimit = "rate_limit"
    }
}

private struct ChatGPTRateLimitPayload: Decodable, Sendable {
    let primaryWindow: ChatGPTUsageWindowPayload?
    let secondaryWindow: ChatGPTUsageWindowPayload?

    enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

private struct ChatGPTUsageWindowPayload: Decodable, Sendable {
    let usedPercent: Double?
    let limitWindowSeconds: Int?
    let resetAt: Double?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case limitWindowSeconds = "limit_window_seconds"
        case resetAt = "reset_at"
    }
}

enum ChatGPTUsagePage {
    private static let exactHost = "chatgpt.com"

    /// Origin-based, mirroring `ClaudeUsagePage`. The old gate pinned the
    /// exact `/codex/cloud/settings/analytics#usage` route — but logged out,
    /// `/codex/settings/usage` redirects to `/`, the gate never matched, and
    /// the fetch script's 401 path (the only signed-out detector) was
    /// unreachable: an expired session showed an endless `stale` badge
    /// instead of Sign In. Any settled chatgpt.com page is a valid session
    /// host — the fetch script enforces the origin itself.
    static func isReady(url: URL?, isLoading: Bool) -> Bool {
        !isLoading && isChatGPTOrigin(url)
    }

    static func isChatGPTOrigin(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host()?.lowercased() == exactHost
            && (url.port == nil || url.port == 443)
    }
}

@MainActor
private enum ChatGPTWebViewPreparation {
    private static let usageURL = URL(
        string: "https://chatgpt.com/codex/settings/usage"
    )!

    static func prepare(_ webView: WKWebView) async throws {
        if ChatGPTUsagePage.isReady(url: webView.url, isLoading: webView.isLoading) {
            return
        }

        if !ChatGPTUsagePage.isChatGPTOrigin(webView.url) {
            webView.load(URLRequest(url: usageURL))
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            try Task.checkCancellation()
            if ChatGPTUsagePage.isReady(
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
