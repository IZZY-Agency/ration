import Foundation
import WebKit

@MainActor
struct CursorProviderAdapter: ProviderAdapter {
    typealias PrepareWebView = @MainActor (WKWebView) async throws -> Void
    /// Where the web view is right now. Injected so tests can script a
    /// redirect; production reads `WKWebView.url` / `isLoading`.
    typealias PageState = @MainActor (WKWebView) -> CursorPageState
    typealias Sleep = @MainActor (Duration) async throws -> Void

    /// How long a failed fetch waits for the page to settle before the
    /// failure is classified (see `classifyFetchFailure`).
    static let settleTimeout: Duration = .seconds(5)
    static let settlePollInterval: Duration = .milliseconds(100)

    let provider = Provider.cursor
    let signInURL = URL(string: "https://cursor.com/dashboard")!

    private let client: WebUsageClient
    private let now: @MainActor () -> Date
    private let prepareWebView: PrepareWebView
    private let pageState: PageState
    private let sleep: Sleep

    init(
        client: WebUsageClient = WebUsageClient(),
        now: @escaping @MainActor () -> Date = { .now },
        prepareWebView: @escaping PrepareWebView = CursorWebViewPreparation.prepare,
        pageState: @escaping PageState = CursorPageState.live,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.client = client
        self.now = now
        self.prepareWebView = prepareWebView
        self.pageState = pageState
        self.sleep = sleep
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

    /// Past cycles for `request`, read on the account's warm dashboard. Runs
    /// in the background (see `AppModel.refreshCursorHistoryInBackground`), so
    /// every failure simply throws and the history is left as it was.
    ///
    /// It NEVER navigates: the view is shared with sign-in/reauth sessions,
    /// and loading the dashboard would pull a visible authenticator page out
    /// from under the user. A view that is not settled on the dashboard (the
    /// poll that just ran put it there) skips this read until another day.
    func fetchCursorSpendHistory(
        _ request: CursorHistoryRequest,
        mayDispatch: @escaping @MainActor () throws -> Void,
        in webView: WKWebView
    ) async throws -> CursorHistoryFetch? {
        let state = pageState(webView)
        guard CursorUsagePage.isReady(url: state.url, isLoading: state.isLoading) else {
            throw ProviderError.transport
        }
        let body = try await responseBody(in: webView) {
            try await client.fetchCursorHistory(
                months: request.months,
                currentPeriodStart: request.currentPeriodStart,
                mayDispatch: mayDispatch,
                in: webView
            )
        }
        return try await Self.parseHistory(body, request: request, now: now())
    }

    private func cursorSpend(in webView: WKWebView) async throws -> CursorSpend {
        let body = try await responseBody(in: webView) {
            try await client.fetchCursor(in: webView)
        }
        return try await Self.parse(body)
    }

    private func responseBody(
        in webView: WKWebView,
        _ read: @MainActor () async throws -> WebResponseEnvelope
    ) async throws -> String {
        do {
            let envelope = try await read()
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
            try await throwIfSettledOnSignIn(webView)
            throw ProviderError.transport
        }
    }

    /// A fetch that failed for a non-provider reason may have been cut off by
    /// Cursor's own sign-out redirect: the dashboard settles for a moment (so
    /// `prepare` returns), the in-page fetch starts, then the page's
    /// client-side redirect to the authenticator tears the frame down. WebKit
    /// then fails the evaluation (`WKErrorDomain` 5, "unsupported type" —
    /// probed 2026-09-26), or the script already finds itself off-origin and
    /// returns `null` (`invalidResponse`). Both used to read as `.transport`,
    /// so an expired session alternated between Sign In and STALE.
    ///
    /// Watches the page for `settleTimeout`. Settled on the authenticator
    /// at any point throws `.authenticationRequired`; otherwise it returns
    /// at the deadline and the caller keeps its original mapping. A settled
    /// dashboard does NOT end the watch early: in the live flap the
    /// dashboard is exactly what looks settled while the redirect is still
    /// to come.
    ///
    /// Not applied to `.timedOut`: a navigation settles the pending call (it
    /// never hangs it), and the timeout must reach `AccountSessionManager`
    /// untouched so the web view is recycled.
    private func throwIfSettledOnSignIn(_ webView: WKWebView) async throws {
        let polls = Int(Self.settleTimeout / Self.settlePollInterval)
        for poll in 0...polls {
            try Task.checkCancellation()
            let state = pageState(webView)
            if CursorUsagePage.isSignInPage(url: state.url, isLoading: state.isLoading) {
                throw ProviderError.authenticationRequired
            }
            if poll < polls {
                try await sleep(Self.settlePollInterval)
            }
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

    /// Decode the history script's compact payload. Every cycle must be one
    /// of the months asked for, closed (ended by `now`, and before the open
    /// cycle), non-overlapping and non-negative; anything else is
    /// `integrationChanged` and the stored history stays as it was.
    nonisolated static func parseHistory(
        _ body: String,
        request: CursorHistoryRequest,
        now: Date
    ) async throws -> CursorHistoryFetch {
        let payload: CursorHistoryPayload
        do {
            payload = try JSONDecoder().decode(CursorHistoryPayload.self, from: Data(body.utf8))
        } catch {
            throw ProviderError.integrationChanged
        }
        let asked = Set(request.months)
        var cycles: [CursorSpendCycle] = []
        for raw in payload.cycles {
            guard
                raw.periodStartMs.isFinite, raw.periodEndMs.isFinite,
                raw.periodStartMs > 0, raw.periodStartMs < raw.periodEndMs,
                raw.spentCents >= 0
            else {
                throw ProviderError.integrationChanged
            }
            let start = Date(timeIntervalSince1970: raw.periodStartMs / 1000)
            let end = Date(timeIntervalSince1970: raw.periodEndMs / 1000)
            let month = CursorSpendHistoryPlanner.month(containing: start)
            // Exactly that UTC calendar month (see the script's invoice check).
            let monthStart = CursorSpendHistoryPlanner.start(of: month)
            let monthEnd = CursorSpendHistoryPlanner.start(of: CursorSpendHistoryPlanner.next(month))
            guard
                asked.contains(month), start == monthStart, end == monthEnd,
                end <= now, end <= request.currentPeriodStart
            else {
                throw ProviderError.integrationChanged
            }
            cycles.append(CursorSpendCycle(periodStart: start, periodEnd: end, spentCents: raw.spentCents, isClosed: true))
        }
        cycles.sort { $0.periodStart < $1.periodStart }
        for index in cycles.indices.dropFirst() where cycles[index - 1].periodEnd > cycles[index].periodStart {
            throw ProviderError.integrationChanged
        }
        var oldest: Date?
        if let oldestMs = payload.oldestEventMs {
            guard oldestMs.isFinite, oldestMs > 0 else { throw ProviderError.integrationChanged }
            oldest = Date(timeIntervalSince1970: oldestMs / 1000)
        }
        return CursorHistoryFetch(cycles: cycles, historyExhausted: payload.historyExhausted, oldestEventAt: oldest)
    }

    /// Map Cursor's raw `membershipType` to a display label. Case-insensitive on
    /// the raw value; an unknown tier falls back to the raw value capitalized
    /// (first letter upper, rest as-is).
    ///
    /// Never localize: the result is persisted as `CursorSpend.planLabel` in
    /// `snapshots.json`, and these are Cursor's plan names.
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
/// field is a changed integration → decode fails → `integrationChanged`).
/// Only fields `CursorSpend` reads are carried (the unused `isYearlyPlan`
/// was dropped); an unknown key in the body is ignored.
private struct CursorSpendPayload: Decodable, Sendable {
    let membershipType: String
    let periodStartMs: Double
    let periodEndMs: Double
    let spentCents: Int
}

/// The compact payload emitted by `WebUsageClient.cursorHistoryScript`.
private struct CursorHistoryPayload: Decodable, Sendable {
    struct Cycle: Decodable, Sendable {
        let periodStartMs: Double
        let periodEndMs: Double
        let spentCents: Int
    }

    let cycles: [Cycle]
    let historyExhausted: Bool
    let oldestEventMs: Double?
}

/// The two `WKWebView` properties the Cursor page checks read.
struct CursorPageState: Equatable, Sendable {
    let url: URL?
    let isLoading: Bool

    @MainActor
    static func live(_ webView: WKWebView) -> CursorPageState {
        CursorPageState(url: webView.url, isLoading: webView.isLoading)
    }
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

    /// Cursor's sign-in host. An expired session redirects the dashboard here
    /// (live-observed 2026-09-26: `authenticator.cursor.sh/?client_id=…`).
    private static let signInHost = "authenticator.cursor.sh"

    /// True once the web view has SETTLED on Cursor's authenticator: the
    /// session is gone and the account needs Sign In. While a redirect is
    /// still loading nothing is decided yet.
    static func isSignInPage(url: URL?, isLoading: Bool) -> Bool {
        guard !isLoading, let url else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host()?.lowercased() == signInHost
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
            // An expired session lands on the authenticator and stays there:
            // waiting out the deadline would report `.transport` (STALE)
            // instead of asking the user to sign in again.
            if CursorUsagePage.isSignInPage(
                url: webView.url,
                isLoading: webView.isLoading
            ) {
                throw ProviderError.authenticationRequired
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw ProviderError.transport
    }
}
