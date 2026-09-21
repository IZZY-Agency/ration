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
