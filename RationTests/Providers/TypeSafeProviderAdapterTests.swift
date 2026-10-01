import WebKit
import XCTest
@testable import Ration

@MainActor
final class TypeSafeProviderAdapterTests: XCTestCase {
    private let t0 = ISO8601DateFormatter().date(from: "2026-09-30T15:00:00Z")!
    /// What the page script posts (see TypeSafeParsingTests for the page side).
    private let billingBody = #"{"balance":26.58,"spent":3.41,"cycleLabel":"September 2026","resetsInDays":1,"autoPay":"off","credits":[{"id":"free-1","amount":5,"remaining":1.58,"expiresAt":"2026-10-17T00:00:00Z","reason":"free_tier_credit"}]}"#
    private let usageRows: [Any] = [["2026-09-30", 5713112, 366115, 5]]

    /// A scripted page: `onLoad` decides what the page does when the billing
    /// page loads (answer, redirect, nothing).
    private final class Page {
        var url: URL? = URL(string: "https://console.typesafe.ai/settings/billing")
        var isLoading = false
        var received = 0
        var body: String?
        var receivedAt: Date?
        var loads: [URL] = []
        var onLoad: (Page) -> Void = { _ in }
    }

    /// `usage` answers the in-page usage script (`fetchTypeSafeUsage`).
    private func adapter(_ page: Page, usage: @escaping () -> Any = { ["status": 500, "days": NSNull()] }) -> TypeSafeProviderAdapter {
        let client = WebUsageClient { script, _, _ in
            if script.contains("__rationTypeSafeDays") { return usage() }
            return NSNull()
        }
        return TypeSafeProviderAdapter(
            client: client,
            now: { self.t0 },
            pageState: { _ in CursorPageState(url: page.url, isLoading: page.isLoading) },
            load: { _, url in page.loads.append(url); page.onLoad(page) },
            capture: { _ in TypeSafeBillingSource(received: { page.received }, take: {
                defer { page.body = nil }
                return page.body.map { ($0, page.receivedAt ?? self.t0) }
            }) },
            sleep: { _ in }
        )
    }

    private func answers(_ body: String) -> (Page) -> Void {
        { page in page.body = body; page.received += 1 }
    }

    func testAReadingBringsBalanceSpendAndDays() async throws {
        let page = Page()
        page.onLoad = answers(billingBody)
        let snap = try await adapter(page, usage: { ["status": 200, "days": self.usageRows] }).fetchUsage(accountID: UUID(), in: WKWebView())

        XCTAssertEqual(page.loads, [TypeSafeProviderAdapter.billingURL], "the billing page loads every time")
        XCTAssertEqual(snap.usageCredits?.balance, Money(minorUnits: 2658, currency: "USD", exponent: 2))
        XCTAssertEqual(snap.usageCredits?.fetchedAt, snap.fetchedAt, "read by this fetch")
        XCTAssertTrue(snap.usageCreditsVerified)
        XCTAssertEqual(snap.typeSafeSpend?.cycleSpent, Money(minorUnits: 341, currency: "USD", exponent: 2))
        XCTAssertEqual(snap.typeSafeDailyUsage?.days.first?.inputTokens, 5713112)
        XCTAssertNil(snap.fiveHour)
        XCTAssertNil(page.body, "the summary is cleared once taken")
    }

    /// Billing and usage are independent: a changed billing page must not
    /// cost the bars, and the carried balance stays display-only.
    func testABillingMissStillSavesTheUsage() async throws {
        let page = Page()
        let snap = try await adapter(page, usage: { ["status": 200, "days": self.usageRows] }).fetchUsage(accountID: UUID(), in: WKWebView())
        XCTAssertNil(snap.usageCredits)
        XCTAssertNil(snap.typeSafeSpend)
        XCTAssertEqual(snap.typeSafeDailyUsage?.days.count, 1)
    }

    func testAnOldBodyIsNotThisLoadsAnswer() async throws {
        let page = Page()
        page.received = 3
        page.body = billingBody
        page.onLoad = { _ in }
        do {
            _ = try await adapter(page).fetchUsage(accountID: UUID(), in: WKWebView())
            XCTFail("a body from before this load must not count")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .transport)
        }
    }

    func testTheLoginMeansSignIn() async throws {
        for login in ["https://login.typesafe.ai/?client=x", "https://console.typesafe.ai/login"] {
            let page = Page()
            page.onLoad = { $0.url = URL(string: login) }
            do {
                _ = try await adapter(page).fetchUsage(accountID: UUID(), in: WKWebView())
                XCTFail(login)
            } catch let error as ProviderError {
                XCTAssertEqual(error, .authenticationRequired, login)
            }
        }
    }

    func testAnUnreadableAnswerIsAChangedIntegrationForVerify() async throws {
        let page = Page()
        page.onLoad = answers(#"{"ok":false}"#)
        do {
            try await adapter(page).verifySession(in: WKWebView())
            XCTFail()
        } catch let error as ProviderError {
            XCTAssertEqual(error, .integrationChanged)
        }
    }

    func testAFailingUsageCallKeepsTheBalance() async throws {
        let page = Page()
        page.onLoad = answers(billingBody)
        let snap = try await adapter(page).fetchUsage(accountID: UUID(), in: WKWebView())
        XCTAssertNotNil(snap.usageCredits)
        XCTAssertNotNil(snap.typeSafeSpend)
        XCTAssertNil(snap.typeSafeDailyUsage, "not read: the store keeps the last bars")
    }

    func testAnExpiredSessionOnTheUsageCallMeansSignIn() async throws {
        let page = Page()
        page.onLoad = answers(billingBody)
        do {
            _ = try await adapter(page, usage: { ["status": 401, "days": NSNull()] }).fetchUsage(accountID: UUID(), in: WKWebView())
            XCTFail()
        } catch let error as ProviderError {
            XCTAssertEqual(error, .authenticationRequired)
        }
    }

    func testNeitherReadIsTheBillingError() async throws {
        let page = Page()
        page.onLoad = answers(#"{"nope":1}"#)
        do {
            _ = try await adapter(page).fetchUsage(accountID: UUID(), in: WKWebView())
            XCTFail()
        } catch let error as ProviderError {
            XCTAssertEqual(error, .integrationChanged)
        }
    }

    func testVerifyNeedsTheBalance() async throws {
        let page = Page()
        page.onLoad = answers(billingBody)
        try await adapter(page).verifySession(in: WKWebView())
        let silent = Page()
        do {
            try await adapter(silent).verifySession(in: WKWebView())
            XCTFail()
        } catch let error as ProviderError {
            XCTAssertEqual(error, .transport)
        }
    }

    // MARK: Capture

    func testTheCaptureAcceptsOnlyTheConsoleOverHTTPS() {
        XCTAssertTrue(TypeSafeBillingCapture.accepts(protocol: "https", host: "console.typesafe.ai", port: 0))
        XCTAssertTrue(TypeSafeBillingCapture.accepts(protocol: "https", host: "console.typesafe.ai", port: 443))
        XCTAssertTrue(TypeSafeBillingCapture.accepts(protocol: "HTTPS", host: "Console.TypeSafe.ai", port: 0))
        XCTAssertFalse(TypeSafeBillingCapture.accepts(protocol: "https", host: "console.typesafe.ai", port: 8443), "another port is another origin")
        XCTAssertFalse(TypeSafeBillingCapture.accepts(protocol: "http", host: "console.typesafe.ai", port: 0))
        XCTAssertFalse(TypeSafeBillingCapture.accepts(protocol: "https", host: "login.typesafe.ai", port: 0))
        XCTAssertFalse(TypeSafeBillingCapture.accepts(protocol: "https", host: "console.typesafe.ai.evil.com", port: 0))
    }

    func testTheCaptureCountsSummariesRefusesHugeOnesAndClearsOnTake() {
        let arrived = t0.addingTimeInterval(-3)
        let capture = TypeSafeBillingCapture(clock: { arrived })
        capture.accept("{}")
        XCTAssertEqual(capture.received, 1)
        capture.accept(String(repeating: "x", count: TypeSafeBilling.maxMessageBytes + 1))
        capture.accept(String(repeating: "é", count: TypeSafeBilling.maxMessageBytes / 2 + 1))
        XCTAssertEqual(capture.received, 1, "the cap is in bytes")
        let taken = capture.take()
        XCTAssertEqual(taken?.summary, "{}")
        XCTAssertEqual(taken?.at, arrived, "dated when it arrived")
        XCTAssertNil(capture.take(), "taken once")
    }

    /// Received just before UTC midnight, picked up just after: the reset
    /// counts from the arrival.
    func testTheResetCountsFromTheArrivalNotThePoll() async throws {
        let page = Page()
        page.receivedAt = ISO8601DateFormatter().date(from: "2026-09-30T23:59:59Z")
        page.onLoad = answers(billingBody)
        let snap = try await adapter(page).fetchUsage(accountID: UUID(), in: WKWebView())
        XCTAssertEqual(snap.typeSafeSpend?.resetsAt, ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        XCTAssertEqual(snap.fetchedAt, page.receivedAt)
    }

    /// The usage request aborts itself well inside the 60 s evaluation, so a
    /// stall returns (keeping the billing read) instead of hanging.
    func testTheUsageScriptCancelsItsOwnRequest() {
        let script = WebUsageClient.typeSafeUsageScript
        XCTAssertTrue(script.contains("setTimeout(() => controller.abort(), 20000)"))
        XCTAssertTrue(script.contains("signal: controller.signal"))
        XCTAssertTrue(script.contains(#"location.origin !== "https://console.typesafe.ai""#))
        XCTAssertTrue(script.contains("__rationTypeSafeDays(parsed)"), "summed in the page")
    }

    func testTheScriptMatchesOnlyTheBillingActionResponse() {
        let script = TypeSafeScripts.capture
        XCTAssertTrue(script.contains(#"method === "POST""#))
        XCTAssertTrue(script.contains(#"url.pathname === "/settings/billing""#))
        XCTAssertTrue(script.contains(#"url.origin === location.origin"#))
        XCTAssertTrue(script.contains("text/x-component"))
        XCTAssertTrue(script.contains("readCapped(response.clone(), 1048576)"), "a byte-capped read of a clone; the page keeps its own response")
        XCTAssertTrue(script.contains("const json = JSON.stringify(summary);"), "only the extracted summary is posted")
        XCTAssertTrue(script.contains("new TextEncoder().encode(json).length > 65536"), "byte-capped in the page too")
        XCTAssertTrue(script.contains("postMessage(json)"))
        XCTAssertFalse(script.contains("postMessage(text)"))
    }

    func testInstallingTwiceKeepsOneCapture() {
        let webView = WKWebView()
        let first = TypeSafeBillingCapture.installed(on: webView)
        let second = TypeSafeBillingCapture.installed(on: webView)
        XCTAssertTrue(first === second)
        XCTAssertEqual(webView.configuration.userContentController.userScripts.filter { $0.source == TypeSafeScripts.capture }.count, 1)
    }

    // MARK: Store

    func testTheStoreCarriesBillingAndUsageApart() async throws {
        let id = UUID()
        let store = UsageSnapshotStore(fileURL: URL(fileURLWithPath: "/dev/null"), saveSnapshots: { _ in })
        let spend = TypeSafeSpend(fetchedAt: t0, cycleSpent: Money(minorUnits: 341, currency: "USD", exponent: 2)!, cycleLabel: nil, resetsAt: nil, autoRecharge: nil)
        let usage = TypeSafeDailyUsage(fetchedAt: t0, days: [TypeSafeDay(day: t0, inputTokens: 5, outputTokens: 1, requests: 1)])
        try await store.save(UsageSnapshot(accountID: id, fetchedAt: t0, fiveHour: nil, weekly: nil, typeSafeSpend: spend, typeSafeDailyUsage: usage))
        try await store.save(UsageSnapshot(accountID: id, fetchedAt: t0.addingTimeInterval(300), fiveHour: nil, weekly: nil, typeSafeSpend: spend))
        XCTAssertEqual(store.snapshot(for: id)?.typeSafeDailyUsage, usage, "billing read, usage missed: the bars carry")
        try await store.save(UsageSnapshot(accountID: id, fetchedAt: t0.addingTimeInterval(600), fiveHour: nil, weekly: nil, typeSafeDailyUsage: usage))
        XCTAssertEqual(store.snapshot(for: id)?.typeSafeSpend, spend, "usage read, billing missed: the spend carries")
    }

    /// A reading restored from disk is never "read this session", even though
    /// its time still equals the restored snapshot's.
    func testARestoredReadingIsNotVerified() throws {
        let credits = UsageCredits(fetchedAt: t0, balance: Money(minorUnits: 1, currency: "USD", exponent: 2)!, grants: [], complete: true, readThisSession: true)
        let live = UsageSnapshot(accountID: UUID(), fetchedAt: t0, fiveHour: nil, weekly: nil, usageCredits: credits)
        XCTAssertTrue(live.usageCreditsVerified)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(UsageSnapshot.self, from: encoder.encode(live))
        XCTAssertEqual(restored.fetchedAt, restored.usageCredits?.fetchedAt)
        XCTAssertFalse(restored.usageCreditsVerified)
    }

    func testProviderBasics() {
        XCTAssertEqual(Provider.typeSafe.displayName, "TypeSafe")
        XCTAssertEqual(Provider.typeSafe.webOrigin, "https://console.typesafe.ai")
        XCTAssertTrue(Provider.typeSafe.matchesAppHost("console.typesafe.ai"))
        XCTAssertFalse(Provider.typeSafe.matchesAppHost("login.typesafe.ai"), "Verify must not light up mid-login")
        XCTAssertEqual(Provider(rawValue: "typesafe"), .typeSafe)
    }
}
