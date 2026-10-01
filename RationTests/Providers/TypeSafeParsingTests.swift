import JavaScriptCore
import XCTest
@testable import Ration

final class TypeSafeParsingTests: XCTestCase {
    private let fetchedAt = ISO8601DateFormatter().date(from: "2026-09-30T15:00:00Z")!
    private func usd(_ cents: Int64) -> Money { Money(minorUnits: cents, currency: "USD", exponent: 2)! }

    /// A live console answer, ids and
    /// private details replaced with obvious fakes.
    private let verified = """
    0:{"a":"$@1","f":"","q":"","i":true}
    1:{"ok":true,"data":{"billing":{"plan":"pay_as_you_go","spent":3.41,"freeCreditsRemaining":1.58,"balance":26.58,"purchased":25,"resetsInDays":1,"cycleLabel":"September 2026","paymentMethod":{"brand":"Visa","last4":"0000","expMonth":1,"expYear":2030},"autoPay":null,"credits":[{"id":"free-1","amount":5,"remaining":1.58,"createdAt":"2026-09-17T00:00:00Z","expiresAt":"2026-10-17T00:00:00Z","reason":"free_tier_credit"},{"id":"bought-1","amount":25,"remaining":25,"createdAt":"2026-09-29T18:58:34.064000Z","expiresAt":"2027-09-29T00:00:00Z","reason":"purchased_credits"}],"invoiceEmail":"someone@example.com","billingAddress":{"line1":"1 Private Street"},"billingAddressValid":false},"payments":[{"id":"pay-1","amount":30}],"hasMore":false,"credits":[]}}
    """

    /// Runs the page script's extraction in JavaScriptCore, as the page does.
    private func extract(_ text: String) throws -> String? {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(TypeSafeScripts.extractBilling)
        let result = context.objectForKeyedSubscript("__rationTypeSafeBilling").call(withArguments: [text])
        guard let result, !result.isNull else { return nil }
        return context.objectForKeyedSubscript("JSON").invokeMethod("stringify", withArguments: [result]).toString()
    }

    // MARK: In the page

    func testThePageSummaryCarriesOnlyThePermittedFields() throws {
        let summary = try XCTUnwrap(extract(verified))
        for secret in ["0000", "Visa", "someone@example.com", "Private Street", "pay-1", "createdAt", "paymentMethod", "invoiceEmail", "billingAddress", "payments", "plan"] {
            XCTAssertFalse(summary.contains(secret), "\(secret) must never cross the bridge: \(summary)")
        }
        let reading = try XCTUnwrap(TypeSafeBilling.parse(summary: summary, fetchedAt: fetchedAt))
        XCTAssertEqual(reading.credits.balance, usd(2658))
        XCTAssertEqual(reading.spend.cycleSpent, usd(341))
        XCTAssertEqual(reading.spend.resetsAt, ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        XCTAssertEqual(reading.spend.autoRecharge, false, "autoPay null is off")
        XCTAssertTrue(reading.credits.complete)
        XCTAssertTrue(reading.credits.readThisSession)
        XCTAssertEqual(reading.credits.grants, [
            UsageCreditGrant(id: "free-1", kind: .free, remaining: usd(158), granted: usd(500), expiresAt: ISO8601DateFormatter().date(from: "2026-10-17T00:00:00Z")),
            UsageCreditGrant(id: "bought-1", kind: .purchased, remaining: usd(2500), granted: usd(2500), expiresAt: ISO8601DateFormatter().date(from: "2027-09-29T00:00:00Z")),
        ])
    }

    /// A field that changed shape carries nothing across: an object where a
    /// string was (with private data inside) becomes null in the page.
    func testAChangedShapeNeverSmugglesDataAcross() throws {
        let changed = #"1:{"data":{"billing":{"balance":26.58,"spent":{"total":3.41,"invoiceEmail":"someone@example.com"},"cycleLabel":{"invoiceEmail":"someone@example.com"},"resetsInDays":"1","credits":[{"id":{"email":"someone@example.com"},"amount":5,"remaining":"1.58","expiresAt":{"card":"0000"},"reason":["x"]},[1,2]]}}}"#
        let summary = try XCTUnwrap(extract(changed))
        XCTAssertFalse(summary.contains("someone@example.com"), summary)
        XCTAssertFalse(summary.contains("0000"), summary)
        XCTAssertNil(TypeSafeBilling.parse(summary: summary, fetchedAt: fetchedAt), "spend is no longer a number: no reading")
    }

    func testThePageFindsTheBillingLineAnywhere() throws {
        let reordered = verified.split(separator: "\n").reversed().joined(separator: "\n")
        XCTAssertNotNil(try extract(reordered))
        XCTAssertNotNil(try extract(verified.replacingOccurrences(of: "1:{\"ok\"", with: "7:{\"ok\"")))
        XCTAssertNil(try extract("0:{\"a\":1}\n1:{\"ok\":false}"))
        XCTAssertNil(try extract("<html>"))
    }

    func testThePageSaysOnOffOrUnknownForAutoRecharge() throws {
        func auto(_ fragment: String) throws -> Bool? {
            let summary = try XCTUnwrap(extract("1:{\"data\":{\"billing\":{\"balance\":1,\"spent\":0,\"credits\":[]\(fragment)}}}"))
            return try XCTUnwrap(TypeSafeBilling.parse(summary: summary, fetchedAt: fetchedAt)).spend.autoRecharge
        }
        XCTAssertEqual(try auto(",\"autoPay\":{\"threshold\":5,\"card\":\"x\"}"), true)
        XCTAssertEqual(try auto(",\"autoPay\":null"), false)
        XCTAssertNil(try auto(""))
    }

    // MARK: In Ration

    func testAMissingGrantListIsNotAnEmptyOne() throws {
        for credits in ["", ",\"credits\":null", ",\"credits\":\"x\""] {
            let summary = try XCTUnwrap(extract("1:{\"data\":{\"billing\":{\"balance\":10,\"spent\":0\(credits)}}}"))
            let reading = try XCTUnwrap(TypeSafeBilling.parse(summary: summary, fetchedAt: fetchedAt))
            XCTAssertFalse(reading.credits.complete, "missing or unreadable grants must not prune alert memory: \(credits)")
        }
        let empty = try XCTUnwrap(extract("1:{\"data\":{\"billing\":{\"balance\":10,\"spent\":0,\"credits\":[]}}}"))
        XCTAssertEqual(try XCTUnwrap(TypeSafeBilling.parse(summary: empty, fetchedAt: fetchedAt)).credits.complete, true, "[] is a real empty list")
    }

    func testMalformedGrantsAreSkippedAndMarkIncomplete() throws {
        let summary = #"{"balance":10,"spent":0,"credits":[{"amount":5,"remaining":5},{"id":"x","remaining":2,"expiresAt":"soon"},null,{"id":"ok","remaining":3,"reason":"gift"},{"id":"spent","remaining":0}]}"#
        let reading = try XCTUnwrap(TypeSafeBilling.parse(summary: summary, fetchedAt: fetchedAt))
        XCTAssertEqual(reading.credits.grants.map(\.id), ["ok"])
        XCTAssertEqual(reading.credits.grants.first?.kind, .promotional, "an unknown reason is not purchased")
        XCTAssertNil(reading.credits.grants.first?.granted, "no amount: unknown, not invented")
        XCTAssertFalse(reading.credits.complete)
    }

    /// A spent grant leaves the card, the warning and Settings, but is kept
    /// apart for the menu-bar gauge's whole, and survives a save.
    func testASpentGrantIsKeptApart() throws {
        let summary = #"{"balance":10,"spent":0,"credits":[{"id":"free","amount":5,"remaining":0,"expiresAt":"2026-10-17T00:00:00Z","reason":"free_tier_credit"},{"id":"bought","amount":25,"remaining":10,"reason":"purchased_credits"}]}"#
        let credits = try XCTUnwrap(TypeSafeBilling.parse(summary: summary, fetchedAt: fetchedAt)).credits
        XCTAssertEqual(credits.grants.map(\.id), ["bought"])
        XCTAssertEqual(credits.spentGrants.map(\.id), ["free"])
        XCTAssertEqual(credits.spentGrants.first?.granted, Money(minorUnits: 500, currency: "USD", exponent: 2))
        XCTAssertTrue(credits.complete)

        let encoder = JSONEncoder(), decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(UsageCredits.self, from: encoder.encode(credits))
        XCTAssertEqual(restored.spentGrants, credits.spentGrants)
        let legacy = try decoder.decode(UsageCredits.self, from: Data(#"{"fetchedAt":"2026-09-30T15:00:00Z","balance":{"minorUnits":1000,"currency":"USD","exponent":2},"grants":[],"complete":true}"#.utf8))
        XCTAssertEqual(legacy.spentGrants, [], "files written before the list existed")
    }

    /// The whole document-start script is valid JavaScript (a syntax error
    /// would silently disable the capture in every page).
    func testTheCaptureScriptParses() throws {
        let context = try XCTUnwrap(JSContext())
        var failure: String?
        context.exceptionHandler = { _, exception in failure = exception?.toString() }
        let source = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: [TypeSafeScripts.capture]), encoding: .utf8))
        context.evaluateScript("new Function(\(source)[0]);")
        XCTAssertNil(failure)
    }

    func testNothingReadableIsNoReading() {
        XCTAssertNil(TypeSafeBilling.parse(summary: "", fetchedAt: fetchedAt))
        XCTAssertNil(TypeSafeBilling.parse(summary: #"{"spent":1}"#, fetchedAt: fetchedAt), "no balance")
        XCTAssertNil(TypeSafeBilling.parse(summary: #"{"balance":1}"#, fetchedAt: fetchedAt), "no spend")
        XCTAssertNil(TypeSafeBilling.parse(summary: #"{"balance":-1,"spent":0}"#, fetchedAt: fetchedAt))
        XCTAssertNil(TypeSafeBilling.parse(summary: String(repeating: " ", count: TypeSafeBilling.maxMessageBytes + 1), fetchedAt: fetchedAt))
        // Counted in UTF-8 bytes: 40,000 two-byte characters are 80,000 bytes.
        XCTAssertNil(TypeSafeBilling.parse(summary: #"{"balance":1,"spent":0,"cycleLabel":""# + String(repeating: "é", count: 40_000) + #""}"#, fetchedAt: fetchedAt))
    }

    func testDollarsRoundToCents() {
        XCTAssertEqual(TypeSafeBilling.usd(Decimal(string: "3.4869")!), usd(349))
        XCTAssertEqual(TypeSafeBilling.usd(Decimal(string: "0.005")!), usd(0), "half to even")
        XCTAssertEqual(TypeSafeBilling.usd(Decimal(string: "0.015")!), usd(2))
        XCTAssertNil(TypeSafeBilling.usd(-1))
    }

    /// The reset is counted from when the answer ARRIVED: one that lands
    /// after UTC midnight counts from the new day.
    func testResetsAtCountsFromTheArrival() throws {
        let summary = #"{"balance":1,"spent":0,"resetsInDays":1,"credits":[]}"#
        let beforeMidnight = ISO8601DateFormatter().date(from: "2026-09-30T23:59:50Z")!
        let afterMidnight = ISO8601DateFormatter().date(from: "2026-10-01T00:00:10Z")!
        XCTAssertEqual(try XCTUnwrap(TypeSafeBilling.parse(summary: summary, fetchedAt: beforeMidnight)).spend.resetsAt, ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"))
        XCTAssertEqual(try XCTUnwrap(TypeSafeBilling.parse(summary: summary, fetchedAt: afterMidnight)).spend.resetsAt, ISO8601DateFormatter().date(from: "2026-10-02T00:00:00Z"))
        XCTAssertNil(TypeSafeBilling.resetsAt(inDays: -1, from: fetchedAt))
    }

    // MARK: Usage

    private func aggregate(_ json: String) throws -> [Any]? {
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript(TypeSafeScripts.aggregateUsage)
        let parsed = context.objectForKeyedSubscript("JSON").invokeMethod("parse", withArguments: [json])
        let result = context.objectForKeyedSubscript("__rationTypeSafeDays").call(withArguments: [parsed as Any])
        guard let result, !result.isNull else { return nil }
        return result.toArray()
    }

    func testThePageSumsPerDayAndDropsIdentities() throws {
        let json = #"{"buckets":[{"day":"2026-09-29T00:00:00.000Z","apiKeyId":"k1","apiKeyName":"Inna's key","userId":null,"userEmail":"a@b.c","requests":3,"inputTokens":1000,"outputTokens":50},{"day":"2026-09-29","apiKeyName":"Agent","requests":2,"inputTokens":500,"outputTokens":10},{"day":"2026-09-30","requests":1,"inputTokens":7,"outputTokens":1},{"day":"bad"},{"day":"2026-9-1x"},42,{"day":"2026-09-30","inputTokens":-5,"requests":"x"}]}"#
        let rows = try XCTUnwrap(aggregate(json))
        XCTAssertFalse(String(describing: rows).contains("Inna"), "key names never leave the page")
        XCTAssertFalse(String(describing: rows).contains("a@b.c"))
        let days = try XCTUnwrap(TypeSafeUsage.days(fromRows: rows))
        XCTAssertEqual(days, [
            TypeSafeDay(day: ISO8601DateFormatter().date(from: "2026-09-29T00:00:00Z")!, inputTokens: 1500, outputTokens: 60, requests: 5),
            TypeSafeDay(day: ISO8601DateFormatter().date(from: "2026-09-30T00:00:00Z")!, inputTokens: 7, outputTokens: 1, requests: 1),
        ])
        XCTAssertNil(try aggregate("{}"))
        XCTAssertEqual(try aggregate(#"{"buckets":[]}"#)?.count, 0)
    }

    func testMalformedRowsAreNoReading() {
        XCTAssertNil(TypeSafeUsage.days(fromRows: [["2026-09-30", 1, 2]]))
        XCTAssertNil(TypeSafeUsage.days(fromRows: [["nope", 1, 2, 3]]))
        XCTAssertNil(TypeSafeUsage.days(fromRows: [["2026-09-30", -1, 2, 3]]))
        XCTAssertEqual(TypeSafeUsage.days(fromRows: [])?.count, 0)
    }

    /// The console's own estimate: $0.042 per million input tokens; the
    /// live 30 days summed to the console's $3.4869.
    func testPriceMatchesTheConsole() {
        let inputs = [7816034, 4187890, 5870021, 3437157, 6562920, 3895772, 5362713, 8476215, 5360650, 14721310, 3807107, 3426547, 4384478, 5713112]
        let total = inputs.map { TypeSafePrice.estimate(inputTokens: $0) }.reduce(0, +)
        XCTAssertEqual(NSDecimalNumber(decimal: total).doubleValue, 3.4869, accuracy: 0.0001)
    }
}
