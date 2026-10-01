import WebKit
import XCTest
@testable import Ration

@MainActor
final class ChatGPTCodexCreditsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    /// The usage response, with the `credits` block verified live on
    /// 2026-09-30 (a Pro 5x account with no credits) spliced in.
    private func usageBody(credits: String?) -> String {
        let block = credits.map { #","credits":"# + $0 } ?? ""
        return #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000,"reset_at":1790010000},"secondary_window":{"used_percent":20,"limit_window_seconds":604800,"reset_at":1790500000}},"plan_type":"prolite""# + block + "}"
    }

    private let verified = #"{"has_credits":false,"unlimited":false,"overage_limit_reached":false,"balance":"0","approx_local_messages":[0,0],"approx_cloud_messages":[0,0]}"#

    private func snapshot(credits: String?) async throws -> UsageSnapshot {
        let body = usageBody(credits: credits)
        let client = WebUsageClient { _, _, _ in
            ["status": 200, "retryAfter": NSNull(), "body": body, "resetCredits": NSNull()]
        }
        let adapter = ChatGPTProviderAdapter(client: client, now: { self.t0 }, prepareWebView: { _ in })
        return try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
    }

    func testTheVerifiedResponseReadsAsZero() async throws {
        let snap = try await snapshot(credits: verified)
        XCTAssertEqual(snap.codexCredits, CodexCredits(fetchedAt: t0, balance: 0, unlimited: false))
        XCTAssertEqual(snap.codexCredits?.isShown, false, "nothing to show for zero")
    }

    func testABalanceAsTextOrNumber() async throws {
        let text = try await snapshot(credits: #"{"has_credits":true,"unlimited":false,"balance":"1250.5"}"#)
        XCTAssertEqual(text.codexCredits?.balance, Decimal(string: "1250.5"))
        XCTAssertEqual(text.codexCredits?.isShown, true)
        let number = try await snapshot(credits: #"{"has_credits":true,"balance":12}"#)
        XCTAssertEqual(number.codexCredits?.balance, 12)
    }

    /// A numeric balance keeps every digit (no `Double` on the way).
    func testALargeNumberKeepsItsDigits() async throws {
        let snap = try await snapshot(credits: #"{"balance":12345678901234567890}"#)
        XCTAssertEqual(snap.codexCredits?.balance, Decimal(string: "12345678901234567890"))
    }

    func testUnlimitedNeedsNoBalance() async throws {
        let snap = try await snapshot(credits: #"{"has_credits":true,"unlimited":true,"balance":null}"#)
        XCTAssertEqual(snap.codexCredits?.unlimited, true)
        XCTAssertEqual(snap.codexCredits?.isShown, true)
    }

    func testAnUnreadableBalanceIsNotRead() async throws {
        for block in [#"{"balance":"12abc"}"#, #"{"balance":"-3"}"#, #"{"balance":"lots"}"#, #"{"balance":""}"#, #"{"has_credits":true}"#, #"{"balance":[1]}"#,
                      #"{"balance":"12.3.4"}"#, #"{"balance":"1-2"}"#, #"{"balance":".5"}"#, #"{"balance":"5."}"#, #"{"balance":-3}"#] {
            let snap = try await snapshot(credits: block)
            XCTAssertNil(snap.codexCredits, block)
            XCTAssertNotNil(snap.weekly, "usage survives: \(block)")
        }
    }

    func testAMissingOrBrokenBlockNeverFailsUsage() async throws {
        for block in [nil, "7", #""credits""#, "null", "[]"] as [String?] {
            let snap = try await snapshot(credits: block)
            XCTAssertNil(snap.codexCredits, block ?? "missing")
            XCTAssertNotNil(snap.fiveHour)
        }
    }

    // MARK: Carried like the other side channels

    func testTheStoreCarriesTheLastReading() async throws {
        let id = UUID()
        let store = UsageSnapshotStore(fileURL: URL(fileURLWithPath: "/dev/null"), saveSnapshots: { _ in })
        let credits = CodexCredits(fetchedAt: t0, balance: 120, unlimited: false)
        try await store.save(UsageSnapshot(accountID: id, fetchedAt: t0, fiveHour: nil, weekly: nil, codexCredits: credits))
        try await store.save(UsageSnapshot(accountID: id, fetchedAt: t0.addingTimeInterval(300), fiveHour: nil, weekly: nil))
        XCTAssertEqual(store.snapshot(for: id)?.codexCredits, credits)
        try await store.save(UsageSnapshot(accountID: id, fetchedAt: t0.addingTimeInterval(600), fiveHour: nil, weekly: nil,
                                           codexCredits: CodexCredits(fetchedAt: t0.addingTimeInterval(600), balance: 0, unlimited: false)))
        XCTAssertEqual(store.snapshot(for: id)?.codexCredits?.balance, 0, "a fresh zero replaces it")
    }

    func testSnapshotRoundTripAndReplacingKeepIt() throws {
        let credits = CodexCredits(fetchedAt: t0, balance: 120, unlimited: false)
        let snap = UsageSnapshot(accountID: UUID(), fetchedAt: t0, fiveHour: nil, weekly: nil, usageCreditsEnabled: true, codexCredits: credits)
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(UsageSnapshot.self, from: encoder.encode(snap)).codexCredits, credits)
        XCTAssertEqual(snap.replacingResetCredits(nil).codexCredits, credits)
        XCTAssertEqual(snap.replacingUsageCredits(nil).codexCredits, credits)
        XCTAssertEqual(snap.replacingUsageCreditsEnabled(nil).codexCredits, credits)
        XCTAssertEqual(snap.replacingCodexCredits(nil).usageCreditsEnabled, true)
    }

    // MARK: Copy

    func testTheLineInEveryLanguage() {
        let credits = CodexCredits(fetchedAt: t0, balance: 1250, unlimited: false)
        XCTAssertEqual(CodexCreditsCopy.line(credits, locale: L10n.en), "Credits 1,250")
        XCTAssertEqual(CodexCreditsCopy.line(credits, locale: L10n.fr), "Crédits 1\u{00A0}250")
        XCTAssertEqual(CodexCreditsCopy.line(credits, locale: L10n.uk), "Кредити 1\u{00A0}250")
        XCTAssertEqual(CodexCreditsCopy.line(CodexCredits(fetchedAt: t0, balance: Decimal(string: "12.5")!, unlimited: false), locale: L10n.en), "Credits 12.5")
        XCTAssertEqual(CodexCreditsCopy.line(CodexCredits(fetchedAt: t0, balance: Decimal(string: "0.001")!, unlimited: false), locale: L10n.en), "Credits 0.001", "a positive balance never reads as 0")
        let unlimited = CodexCredits(fetchedAt: t0, balance: 0, unlimited: true)
        XCTAssertEqual(CodexCreditsCopy.line(unlimited, locale: L10n.fr), "Crédits illimités")
        XCTAssertEqual(CodexCreditsCopy.spoken(credits, locale: L10n.en), "Codex credits: 1,250.")
        XCTAssertEqual(CodexCreditsCopy.spoken(unlimited, locale: L10n.uk), "Кредити Codex: без обмежень.")
        XCTAssertEqual(CodexCreditsCopy.settingsValue(unlimited, locale: L10n.en), "Unlimited")
        XCTAssertEqual(CodexCreditsCopy.footnote(locale: L10n.en), "Buy Codex credits on chatgpt.com. Ration only shows them.")
    }

    func testWhenTheLineShows() {
        XCTAssertFalse(CodexCreditsCopy.shows(nil, now: t0))
        XCTAssertFalse(CodexCreditsCopy.shows(CodexCredits(fetchedAt: t0, balance: 0, unlimited: false), now: t0))
        XCTAssertTrue(CodexCreditsCopy.shows(CodexCredits(fetchedAt: t0, balance: 1, unlimited: false), now: t0))
        XCTAssertFalse(CodexCreditsCopy.shows(CodexCredits(fetchedAt: t0, balance: 1, unlimited: false), now: t0.addingTimeInterval(UsageCreditsSummary.hideAfter + 1)), "a day-old reading is not shown")
    }
}
