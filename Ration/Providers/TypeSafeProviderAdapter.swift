import Foundation
import os
import WebKit

/// TypeSafe (console.typesafe.ai): a prepaid balance with credit grants, this
/// cycle's spend and per-day usage. See docs/provider-contracts/typesafe.md.
///
/// Every refresh loads the console's billing page, whose own server action
/// brings the balance (summarised in the page by `TypeSafeBillingCapture`),
/// then reads the per-day usage on that page (`fetchTypeSafeUsage`). The two
/// are independent: either can fail while the other still lands.
@MainActor
struct TypeSafeProviderAdapter: ProviderAdapter {
    typealias PageState = @MainActor (WKWebView) -> CursorPageState
    typealias Load = @MainActor (WKWebView, URL) -> Void
    /// The capture for a web view. Injected so tests can script the page.
    typealias Capture = @MainActor (WKWebView) -> TypeSafeBillingSource
    typealias Sleep = @MainActor (Duration) async throws -> Void

    static let billingURL = URL(string: "https://console.typesafe.ai/settings/billing")!
    private static let log = Logger(subsystem: "agency.izzy.ration", category: "typesafe")
    /// Covers the page load, Cloudflare's automatic check and the action.
    static let captureTimeout: Duration = .seconds(30)
    static let pollInterval: Duration = .milliseconds(100)

    let provider = Provider.typeSafe
    let signInURL = Self.billingURL

    private let client: WebUsageClient
    private let now: @MainActor () -> Date
    private let pageState: PageState
    private let load: Load
    private let capture: Capture
    private let sleep: Sleep

    init(
        client: WebUsageClient = WebUsageClient(),
        now: @escaping @MainActor () -> Date = { .now },
        pageState: @escaping PageState = CursorPageState.live,
        load: @escaping Load = { webView, url in webView.load(URLRequest(url: url)) },
        capture: @escaping Capture = { TypeSafeBillingSource.live(TypeSafeBillingCapture.installed(on: $0)) },
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.now = now
        self.pageState = pageState
        self.load = load
        self.capture = capture
        self.sleep = sleep
    }

    /// "Verified" means the balance was actually read.
    func verifySession(in webView: WKWebView) async throws {
        _ = try await billing(in: webView)
    }

    func fetchUsage(accountID: UUID, in webView: WKWebView) async throws -> UsageSnapshot {
        var reading: TypeSafeBillingReading?
        var billingError: Error?
        do {
            reading = try await billing(in: webView)
        } catch let error as ProviderError where error == .authenticationRequired {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            billingError = error
        }
        let usage = try await dailyUsage(in: webView)
        guard reading != nil || usage != nil else {
            throw billingError ?? ProviderError.transport
        }
        // The balance's own arrival time, so the reading counts as this
        // fetch's (`usageCreditsVerified`); a billing miss keeps the last
        // one, carried and display-only.
        return UsageSnapshot(
            accountID: accountID,
            fetchedAt: reading?.credits.fetchedAt ?? usage?.fetchedAt ?? now(),
            fiveHour: nil,
            weekly: nil,
            usageCredits: reading?.credits,
            typeSafeSpend: reading?.spend,
            typeSafeDailyUsage: usage
        )
    }

    /// Loads the billing page and waits for the page's own billing summary.
    /// Settling on the login throws `.authenticationRequired`; no summary in
    /// time is `.transport`; an unreadable one is `.integrationChanged`. The
    /// reading is dated when the summary arrived.
    private func billing(in webView: WKWebView) async throws -> TypeSafeBillingReading {
        let source = capture(webView)
        let before = source.received()
        load(webView, Self.billingURL)
        let polls = Int(Self.captureTimeout / Self.pollInterval)
        // Outcomes only (never a figure), so a balance that stops arriving
        // can be told apart from one that is merely unchanged.
        for poll in 0..<polls {
            try Task.checkCancellation()
            if source.received() > before, let taken = source.take() {
                guard let reading = TypeSafeBilling.parse(summary: taken.summary, fetchedAt: taken.at) else {
                    Self.log.error("typesafe billing: unreadable summary")
                    throw ProviderError.integrationChanged
                }
                Self.log.info("typesafe billing: arrived after \(Double(poll) * 0.1, format: .fixed(precision: 1), privacy: .public)s complete=\(reading.credits.complete, privacy: .public) grants=\(reading.credits.grants.count, privacy: .public) spent=\(reading.credits.spentGrants.count, privacy: .public)")
                return reading
            }
            let state = pageState(webView)
            if TypeSafeConsolePage.isSignInPage(url: state.url, isLoading: state.isLoading) {
                Self.log.error("typesafe billing: sign-in page")
                throw ProviderError.authenticationRequired
            }
            try await sleep(Self.pollInterval)
        }
        let state = pageState(webView)
        // Live 2026-10-01: a background read lands on Cloudflare's bot check
        // ("Just a moment...") once the pass from the visible sign-in expires.
        let cloudflare = (webView.title ?? "").hasPrefix("Just a moment")
        Self.log.error("typesafe billing: no answer in 30s host=\(state.url?.host() ?? "-", privacy: .public) path=\(state.url?.path ?? "-", privacy: .public) loading=\(state.isLoading, privacy: .public) cloudflareCheck=\(cloudflare, privacy: .public)")
        throw ProviderError.transport
    }

    /// nil when the usage call fails for any reason but an expired session
    /// or a timeout (those propagate as for every provider).
    private func dailyUsage(in webView: WKWebView) async throws -> TypeSafeDailyUsage? {
        let result: (status: Int, rows: [Any]?)
        do {
            result = try await client.fetchTypeSafeUsage(in: webView)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WebUsageClientError where error == .timedOut {
            throw error
        } catch {
            return nil
        }
        if result.status == 401 { throw ProviderError.authenticationRequired }
        guard (200..<300).contains(result.status), let rows = result.rows, let days = TypeSafeUsage.days(fromRows: rows) else { return nil }
        return TypeSafeDailyUsage(fetchedAt: now(), days: days)
    }
}

/// The three things the adapter does with a capture.
struct TypeSafeBillingSource {
    let received: @MainActor () -> Int
    /// The latest summary and when it arrived, cleared as it is taken.
    let take: @MainActor () -> (summary: String, at: Date)?

    @MainActor
    static func live(_ capture: TypeSafeBillingCapture) -> TypeSafeBillingSource {
        TypeSafeBillingSource(received: { capture.received }, take: { capture.take() })
    }
}

enum TypeSafeConsolePage {
    /// Settled on the sign-in: `login.typesafe.ai`, or the console's own
    /// `/login` (signed out, the console redirects there first).
    static func isSignInPage(url: URL?, isLoading: Bool) -> Bool {
        guard !isLoading, let url, url.scheme?.lowercased() == "https", let host = url.host()?.lowercased() else { return false }
        if host == "login.typesafe.ai" { return true }
        return host == "console.typesafe.ai" && url.path == "/login"
    }
}
