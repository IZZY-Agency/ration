import WebKit
import XCTest
@testable import Ration

@MainActor
final class CursorProviderAdapterTests: XCTestCase {
    // MARK: - parse: the deterministic, unit-tested core

    func testDecodesCompactPayload() async throws {
        let body = #"{"membershipType":"pro","isYearlyPlan":false,"periodStartMs":1000000,"periodEndMs":5000000,"spentCents":1234}"#
        let spend = try await CursorProviderAdapter.parse(body)
        XCTAssertEqual(spend.spentCents, 1234)
        XCTAssertEqual(spend.resetsAt, Date(timeIntervalSince1970: 5000))
        XCTAssertEqual(spend.planLabel, "Pro")
    }

    /// `isYearlyPlan` was decoded but never read, so the payload no
    /// longer carries it. The current shape decodes; a body that still has
    /// the field (the older shape) decodes too, the key simply ignored.
    func testDecodesPayloadWithoutIsYearlyPlan() async throws {
        let body = #"{"membershipType":"pro","periodStartMs":1000000,"periodEndMs":5000000,"spentCents":1234}"#
        let spend = try await CursorProviderAdapter.parse(body)
        XCTAssertEqual(spend.spentCents, 1234)
        XCTAssertEqual(spend.planLabel, "Pro")
    }

    func testFetchScriptEmitsOnlyFieldsTheAdapterReads() async throws {
        let captured = CapturedScript()
        let client = WebUsageClient { script, _, _ in
            captured.value = script
            return [
                "status": 200,
                "retryAfter": NSNull(),
                "body": #"{"membershipType":"pro","periodStartMs":1000000,"periodEndMs":5000000,"spentCents":0}"#
            ]
        }
        _ = try await client.fetchCursor(in: WKWebView())
        let script = try XCTUnwrap(captured.value)
        XCTAssertTrue(script.contains("spentCents: Math.round(spentCents)"), "wrong script captured")
        XCTAssertFalse(script.contains("isYearlyPlan"), "isYearlyPlan is unused and must not be emitted")
    }

    func testResetsAtConvertsMillisecondsToSeconds() async throws {
        // periodEndMs is milliseconds; resetsAt divides by 1000.
        let body = #"{"membershipType":"ultra","isYearlyPlan":true,"periodStartMs":1000000,"periodEndMs":1784487780000,"spentCents":0}"#
        let spend = try await CursorProviderAdapter.parse(body)
        XCTAssertEqual(spend.resetsAt, Date(timeIntervalSince1970: 1_784_487_780))
    }

    func testDecodesPeriodStart() async throws {
        // periodStartMs is milliseconds too; periodStart divides by 1000.
        let body = #"{"membershipType":"pro","isYearlyPlan":false,"periodStartMs":1000000,"periodEndMs":5000000,"spentCents":0}"#
        let spend = try await CursorProviderAdapter.parse(body)
        XCTAssertEqual(spend.periodStart, Date(timeIntervalSince1970: 1000))
    }

    /// Live-observed 2026-08-27: `get-monthly-invoice` now reports
    /// `periodEndMs` as the fetch time for the open invoice, so the period
    /// START is the only field that identifies the billing cycle. A payload
    /// without it is a changed integration, never a guessed cycle.
    func testMissingPeriodStartIsIntegrationChanged() async {
        await assertIntegrationChanged(
            #"{"membershipType":"pro","isYearlyPlan":false,"periodEndMs":5000000,"spentCents":0}"#
        )
    }

    func testPeriodStartNotBeforePeriodEndIsIntegrationChanged() async {
        await assertIntegrationChanged(
            #"{"membershipType":"pro","isYearlyPlan":false,"periodStartMs":5000000,"periodEndMs":5000000,"spentCents":0}"#
        )
        await assertIntegrationChanged(
            #"{"membershipType":"pro","isYearlyPlan":false,"periodStartMs":6000000,"periodEndMs":5000000,"spentCents":0}"#
        )
    }

    func testLargeOverageSpendPassesThrough() async throws {
        // Usage-based spend can exceed the plan's included budget; a large
        // positive value is legitimate and must pass through untouched.
        let body = #"{"membershipType":"pro","isYearlyPlan":false,"periodStartMs":1000000,"periodEndMs":5000000,"spentCents":98765}"#
        let spend = try await CursorProviderAdapter.parse(body)
        XCTAssertEqual(spend.spentCents, 98765)
        XCTAssertEqual(spend.spentDollars, 987.65, accuracy: 0.0001)
    }

    func testZeroSpendPassesThrough() async throws {
        let body = #"{"membershipType":"free","isYearlyPlan":false,"periodStartMs":1000000,"periodEndMs":5000000,"spentCents":0}"#
        let spend = try await CursorProviderAdapter.parse(body)
        XCTAssertEqual(spend.spentCents, 0)
    }

    // MARK: - planLabel mapping (case-insensitive on the raw value)

    func testPlanLabelMapsKnownTiers() async throws {
        try await assertPlanLabel("pro", "Pro")
        try await assertPlanLabel("pro_plus", "Pro+")
        try await assertPlanLabel("pro-plus", "Pro+")
        try await assertPlanLabel("ultra", "Ultra")
        try await assertPlanLabel("free", "Free")
    }

    func testPlanLabelMappingIsCaseInsensitive() async throws {
        try await assertPlanLabel("PRO", "Pro")
        try await assertPlanLabel("Pro_Plus", "Pro+")
        try await assertPlanLabel("ULTRA", "Ultra")
    }

    func testPlanLabelUnknownTierCapitalizesRawValue() async throws {
        // Unknown → first letter upper, rest as-is (no lowercasing of the tail).
        try await assertPlanLabel("enterprise", "Enterprise")
        try await assertPlanLabel("team", "Team")
        try await assertPlanLabel("business_plus", "Business_plus")
    }

    // MARK: - Validation → integrationChanged (never invent a value)

    func testMissingPeriodEndIsIntegrationChanged() async {
        await assertIntegrationChanged(#"{"membershipType":"pro","isYearlyPlan":false,"spentCents":0}"#)
    }

    func testZeroPeriodEndIsIntegrationChanged() async {
        await assertIntegrationChanged(
            #"{"membershipType":"pro","isYearlyPlan":false,"periodStartMs":1000000,"periodEndMs":0,"spentCents":0}"#
        )
    }

    func testNegativePeriodEndIsIntegrationChanged() async {
        await assertIntegrationChanged(
            #"{"membershipType":"pro","isYearlyPlan":false,"periodStartMs":1000000,"periodEndMs":-1,"spentCents":0}"#
        )
    }

    func testNegativeSpentCentsIsIntegrationChanged() async {
        await assertIntegrationChanged(
            #"{"membershipType":"pro","isYearlyPlan":false,"periodStartMs":1000000,"periodEndMs":5000000,"spentCents":-1}"#
        )
    }

    func testMalformedJSONIsIntegrationChanged() async {
        await assertIntegrationChanged("not json at all")
    }

    func testEmptyBodyIsIntegrationChanged() async {
        await assertIntegrationChanged("")
    }

    func testEmptyMembershipTypeIsIntegrationChanged() async {
        // A blank tier would render a label-less plan tag. The in-page script
        // rejects it upstream; the decode boundary rejects it too.
        await assertIntegrationChanged(
            #"{"membershipType":"","isYearlyPlan":false,"periodStartMs":1000000,"periodEndMs":5000000,"spentCents":0}"#
        )
    }

    func testHTMLCatchAllBodyIsIntegrationChanged() async {
        // cursor.com's SPA serves HTML with HTTP **200** for a removed endpoint
        // (live-verified 2026-07-28), so a status check can never catch it — the
        // shape check must. The script converts this to an empty body, but assert
        // the raw HTML case too so the decode boundary is provably safe.
        await assertIntegrationChanged("<!DOCTYPE html><html lang=\"en\"><head>")
    }

    func testPeriodEndAsRawStringIsIntegrationChanged() async {
        // The in-page script normalizes Cursor's STRING periodEndMs to a number;
        // if a string slips through, decode fails → integrationChanged (no guess).
        await assertIntegrationChanged(
            #"{"membershipType":"pro","isYearlyPlan":false,"periodStartMs":1000000,"periodEndMs":"5000000","spentCents":0}"#
        )
    }

    // MARK: - Page readiness

    func testUsagePageRequiresExactCursorDashboardRoute() {
        XCTAssertTrue(
            CursorUsagePage.isReady(
                url: URL(string: "https://cursor.com/dashboard"),
                isLoading: false
            )
        )
        XCTAssertFalse(
            CursorUsagePage.isReady(
                url: URL(string: "https://cursor.com/dashboard"),
                isLoading: true
            )
        )
        XCTAssertFalse(
            CursorUsagePage.isReady(
                url: URL(string: "https://www.cursor.com/dashboard"),
                isLoading: false
            )
        )
        XCTAssertFalse(
            CursorUsagePage.isReady(
                url: URL(string: "https://cursor.com/settings"),
                isLoading: false
            )
        )
        XCTAssertFalse(
            CursorUsagePage.isReady(
                url: URL(string: "http://cursor.com/dashboard"),
                isLoading: false
            )
        )
    }

    /// An expired Cursor session sends `cursor.com/dashboard` to Cursor's
    /// authenticator (live-observed 2026-09-26). Once the redirect has
    /// settled there, the account needs Sign In — not a 30 s wait that ends
    /// in `.transport` and a STALE badge.
    func testSettledOnTheAuthenticatorIsTheSignInPage() {
        let authenticator = URL(
            string: "https://authenticator.cursor.sh/?client_id=x&redirect_uri=https%3A%2F%2Fcursor.com%2Fapi%2Fauth%2Fcallback"
        )
        XCTAssertTrue(CursorUsagePage.isSignInPage(url: authenticator, isLoading: false))
        // Still redirecting: not decided yet.
        XCTAssertFalse(CursorUsagePage.isSignInPage(url: authenticator, isLoading: true))
        // The dashboard itself, another cursor.com page, or no URL yet: not sign-in.
        XCTAssertFalse(
            CursorUsagePage.isSignInPage(url: URL(string: "https://cursor.com/dashboard"), isLoading: false)
        )
        XCTAssertFalse(
            CursorUsagePage.isSignInPage(url: URL(string: "https://cursor.com/settings"), isLoading: false)
        )
        XCTAssertFalse(CursorUsagePage.isSignInPage(url: nil, isLoading: false))
        // Look-alike hosts are not Cursor's authenticator.
        XCTAssertFalse(
            CursorUsagePage.isSignInPage(
                url: URL(string: "https://authenticator.cursor.sh.example.com/"),
                isLoading: false
            )
        )
        XCTAssertFalse(
            CursorUsagePage.isSignInPage(url: URL(string: "http://authenticator.cursor.sh/"), isLoading: false)
        )
    }

    // MARK: - Adapter wiring

    func testAdapterIdentity() {
        let adapter = CursorProviderAdapter(prepareWebView: { _ in })
        XCTAssertEqual(adapter.provider, .cursor)
        XCTAssertEqual(adapter.signInURL, URL(string: "https://cursor.com/dashboard"))
    }

    func testFetchUsageDecodesCursorSpendFromClientEnvelope() async throws {
        let fetchedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let client = WebUsageClient { _, _, _ in
            [
                "status": 200,
                "retryAfter": NSNull(),
                "body": #"{"membershipType":"pro","isYearlyPlan":false,"periodStartMs":1000000,"periodEndMs":5000000,"spentCents":1234}"#
            ]
        }
        let adapter = CursorProviderAdapter(
            client: client,
            now: { fetchedAt },
            prepareWebView: { _ in }
        )
        let accountID = UUID()

        let snapshot = try await adapter.fetchUsage(
            accountID: accountID,
            in: WKWebView()
        )

        XCTAssertEqual(snapshot.accountID, accountID)
        XCTAssertEqual(snapshot.fetchedAt, fetchedAt)
        XCTAssertNil(snapshot.fiveHour)
        XCTAssertNil(snapshot.weekly)
        XCTAssertNil(snapshot.modelWeekly)
        let spend = try XCTUnwrap(snapshot.cursorSpend)
        XCTAssertEqual(spend.spentCents, 1234)
        XCTAssertEqual(spend.resetsAt, Date(timeIntervalSince1970: 5000))
        XCTAssertEqual(spend.planLabel, "Pro")
    }

    /// The history read never navigates: off the dashboard (e.g. a reauth
    /// session left the view on the authenticator) it neither loads the
    /// dashboard nor dispatches a script.
    func testHistoryReadOffTheDashboardNeverNavigatesOrDispatches() async {
        var evaluations = 0
        var prepares = 0
        let client = WebUsageClient { _, _, _ in
            evaluations += 1
            return nil
        }
        let adapter = CursorProviderAdapter(
            client: client,
            prepareWebView: { _ in prepares += 1 },
            pageState: { _ in
                CursorPageState(url: URL(string: "https://authenticator.cursor.sh/?client_id=x"), isLoading: false)
            },
            sleep: { _ in }
        )
        let request = CursorHistoryRequest(
            months: [CursorInvoiceMonth(year: 2026, month: 7)],
            currentPeriodStart: Date(timeIntervalSince1970: 1_788_220_800)
        )
        do {
            _ = try await adapter.fetchCursorSpendHistory(request, mayDispatch: {}, in: WKWebView())
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? ProviderError, .transport)
        }
        XCTAssertEqual(prepares, 0)
        XCTAssertEqual(evaluations, 0)
    }

    func testFetchUsageMapsUnauthorizedToAuthenticationRequired() async {
        let client = WebUsageClient { _, _, _ in
            ["status": 401, "retryAfter": NSNull(), "body": ""]
        }
        let adapter = CursorProviderAdapter(
            client: client,
            prepareWebView: { _ in }
        )

        do {
            _ = try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
            XCTFail("Expected authenticationRequired")
        } catch {
            XCTAssertEqual(error as? ProviderError, .authenticationRequired)
        }
    }

    func testVerifyPreservesCancellationFromUsageFetch() async {
        let client = WebUsageClient { _, _, _ in
            throw CancellationError()
        }
        let adapter = CursorProviderAdapter(
            client: client,
            prepareWebView: { _ in }
        )

        do {
            try await adapter.verifySession(in: WKWebView())
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: refresh coordination relies on cancellation remaining cancellation.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    // A hung JS-bridge evaluation must surface as `.timedOut`, not get
    // wrapped into `.transport` by `responseBody`'s catch-all —
    // `AccountSessionManager` keys its web-view recycle on `.timedOut`.
    func testTimedOutPassesThroughUntouched() async {
        let adapter = CursorProviderAdapter(
            client: WebUsageClient(
                evaluator: { _, _, _ in
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                    return nil
                },
                sleep: { _ in }
            ),
            prepareWebView: { _ in }
        )
        do {
            _ = try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
            XCTFail("expected timedOut")
        } catch let error as WebUsageClientError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("timedOut must pass through, got \(error)")
        }
    }

    // MARK: - Fetch cut off by the sign-out redirect (1.6.0 Sign In ↔ STALE flap)

    private static let dashboard = URL(string: "https://cursor.com/dashboard")!
    private static let authenticator = URL(string: "https://authenticator.cursor.sh/?client_id=x")!

    /// What WebKit throws when a navigation tears down the frame under a
    /// pending `callAsyncJavaScript` (probed 2026-09-26: WKErrorDomain 5).
    private static let interruptedEvaluation = NSError(
        domain: WKError.errorDomain,
        code: WKError.Code.javaScriptResultTypeIsUnsupported.rawValue
    )

    private func adapter(
        evaluator: @escaping WebUsageClient.Evaluator,
        pages: ScriptedPages,
        sleep: @escaping CursorProviderAdapter.Sleep = { _ in }
    ) -> CursorProviderAdapter {
        CursorProviderAdapter(
            client: WebUsageClient(evaluator: evaluator),
            prepareWebView: { _ in },
            pageState: { _ in pages.next() },
            sleep: sleep
        )
    }

    func testInterruptedFetchThatSettlesOnTheAuthenticatorAsksToSignIn() async {
        let pages = ScriptedPages([
            CursorPageState(url: Self.dashboard, isLoading: true),
            CursorPageState(url: Self.authenticator, isLoading: true),
            CursorPageState(url: Self.authenticator, isLoading: false)
        ])
        let adapter = adapter(
            evaluator: { _, _, _ in throw Self.interruptedEvaluation },
            pages: pages
        )
        await assertFetchThrows(adapter, .authenticationRequired)
        XCTAssertEqual(pages.reads, 3, "polls until the redirect settles")
    }

    /// Off-origin the script returns `null` → `invalidResponse`. Same cause.
    func testOffOriginNullOnTheAuthenticatorAsksToSignIn() async {
        let pages = ScriptedPages([CursorPageState(url: Self.authenticator, isLoading: false)])
        let adapter = adapter(evaluator: { _, _, _ in NSNull() }, pages: pages)
        await assertFetchThrows(adapter, .authenticationRequired)
    }

    /// The live flap: the dashboard looks settled when the fetch fails, and
    /// Cursor's client-side redirect only fires 1.5 s later. A settled
    /// dashboard must not end the watch early.
    func testSettledDashboardThenLateRedirectAsksToSignIn() async {
        let polls = Int(Duration.milliseconds(1500) / CursorProviderAdapter.settlePollInterval)
        var states = Array(
            repeating: CursorPageState(url: Self.dashboard, isLoading: false),
            count: polls
        )
        states.append(CursorPageState(url: Self.authenticator, isLoading: true))
        states.append(CursorPageState(url: Self.authenticator, isLoading: false))
        let pages = ScriptedPages(states)
        let slept = SleepLog()
        let adapter = adapter(
            evaluator: { _, _, _ in throw Self.interruptedEvaluation },
            pages: pages,
            sleep: { slept.durations.append($0) }
        )
        await assertFetchThrows(adapter, .authenticationRequired)
        XCTAssertEqual(pages.reads, polls + 2)
        XCTAssertEqual(slept.total, .milliseconds(1600))
    }

    /// Stays on the dashboard: watched for the whole bound, then `.transport`.
    func testFailedFetchThatStaysOnTheDashboardIsTransportAfterTheBound() async {
        let pages = ScriptedPages([CursorPageState(url: Self.dashboard, isLoading: false)])
        let slept = SleepLog()
        let adapter = adapter(
            evaluator: { _, _, _ in throw Self.interruptedEvaluation },
            pages: pages,
            sleep: { slept.durations.append($0) }
        )
        await assertFetchThrows(adapter, .transport)
        XCTAssertEqual(slept.total, CursorProviderAdapter.settleTimeout)
        XCTAssertEqual(pages.reads, slept.durations.count + 1)
    }

    /// A page that never settles is waited out for `settleTimeout`, no more.
    func testSettleWaitIsBounded() async {
        let pages = ScriptedPages([CursorPageState(url: Self.dashboard, isLoading: true)])
        let slept = SleepLog()
        let adapter = adapter(
            evaluator: { _, _, _ in throw Self.interruptedEvaluation },
            pages: pages,
            sleep: { slept.durations.append($0) }
        )
        await assertFetchThrows(adapter, .transport)
        XCTAssertEqual(slept.total, CursorProviderAdapter.settleTimeout)
        XCTAssertEqual(pages.reads, slept.durations.count + 1)
    }

    func testSettleWaitStopsOnCancellation() async {
        let pages = ScriptedPages([CursorPageState(url: Self.dashboard, isLoading: false)])
        let adapter = adapter(
            evaluator: { _, _, _ in throw Self.interruptedEvaluation },
            pages: pages,
            sleep: { try await Task.sleep(for: $0) }
        )
        let task = Task { @MainActor in
            try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
        }
        // Let it reach the settle wait (bounded, so a regression fails
        // instead of hanging), then cancel.
        let clock = ContinuousClock()
        let reachDeadline = clock.now.advanced(by: .seconds(3))
        while pages.reads == 0, clock.now < reachDeadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(pages.reads, 0, "never reached the settle wait")
        task.cancel()
        let started = clock.now
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            XCTAssertLessThan(clock.now - started, .seconds(2))
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }

    /// The timeout keeps its passthrough even when the view shows the
    /// authenticator: `AccountSessionManager` recycles the web view on it,
    /// and a navigation settles a pending call rather than hanging it.
    func testTimedOutPassesThroughWithoutWaitingForTheRedirect() async {
        let pages = ScriptedPages([CursorPageState(url: Self.authenticator, isLoading: false)])
        let adapter = CursorProviderAdapter(
            client: WebUsageClient(
                evaluator: { _, _, _ in
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                    return nil
                },
                sleep: { _ in }
            ),
            prepareWebView: { _ in },
            pageState: { _ in pages.next() },
            sleep: { _ in }
        )
        do {
            _ = try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
            XCTFail("expected timedOut")
        } catch let error as WebUsageClientError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("timedOut must pass through, got \(error)")
        }
        XCTAssertEqual(pages.reads, 0)
    }

    /// The script's first request is `/api/auth/stripe`; a 401/403 there comes
    /// back as that status and `ProviderResponseValidator` maps it to Sign In
    /// with no settle wait.
    func testForbiddenFromTheFirstRequestAsksToSignIn() async {
        let pages = ScriptedPages([CursorPageState(url: Self.dashboard, isLoading: false)])
        let adapter = adapter(
            evaluator: { _, _, _ in ["status": 403, "retryAfter": NSNull(), "body": ""] },
            pages: pages
        )
        await assertFetchThrows(adapter, .authenticationRequired)
        XCTAssertEqual(pages.reads, 0)
    }

    private func assertFetchThrows(
        _ adapter: CursorProviderAdapter,
        _ expected: ProviderError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ProviderError, expected, file: file, line: line)
        }
    }

    // MARK: - Helpers (do/catch idiom; this suite has no async-throws helper)

    private func assertPlanLabel(
        _ membershipType: String,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let body = """
        {"membershipType":"\(membershipType)","isYearlyPlan":false,"periodStartMs":1000000,"periodEndMs":5000000,"spentCents":0}
        """
        let spend = try await CursorProviderAdapter.parse(body)
        XCTAssertEqual(spend.planLabel, expected, file: file, line: line)
    }

    private func assertIntegrationChanged(
        _ body: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await CursorProviderAdapter.parse(body)
            XCTFail("Expected integrationChanged", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? ProviderError,
                .integrationChanged,
                file: file,
                line: line
            )
        }
    }
}

@MainActor
private final class CapturedScript {
    var value: String?
}

/// Page states read in order; the last one repeats.
@MainActor
private final class ScriptedPages {
    private let states: [CursorPageState]
    private(set) var reads = 0

    init(_ states: [CursorPageState]) {
        self.states = states
    }

    func next() -> CursorPageState {
        let index = min(reads, states.count - 1)
        reads += 1
        return states[index]
    }
}

@MainActor
private final class SleepLog {
    var durations: [Duration] = []

    var total: Duration {
        var sum = Duration.zero
        for duration in durations {
            sum += duration
        }
        return sum
    }
}
