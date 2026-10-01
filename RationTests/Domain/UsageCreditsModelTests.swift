import XCTest
@testable import Ration

final class UsageCreditsModelTests: XCTestCase {
    // MARK: Money

    func testMoneyNormalisesTheCurrencyAndKeepsTheExactAmount() throws {
        let money = try XCTUnwrap(Money(minorUnits: 1000, currency: "eur", exponent: 2))
        XCTAssertEqual(money.currency, "EUR")
        XCTAssertEqual(money.decimalValue, Decimal(10))
        XCTAssertEqual(try XCTUnwrap(Money(minorUnits: 5, currency: "EUR", exponent: 2)).decimalValue, Decimal(string: "0.05"))
        XCTAssertEqual(try XCTUnwrap(Money(minorUnits: 100_000, currency: "JPY", exponent: 0)).decimalValue, Decimal(100_000))
    }

    func testMoneyRefusesWhatCannotBeAnAmount() {
        XCTAssertNil(Money(minorUnits: -1, currency: "EUR", exponent: 2))
        XCTAssertNil(Money(minorUnits: 1, currency: "", exponent: 2))
        XCTAssertNil(Money(minorUnits: 1, currency: "EURO", exponent: 2))
        XCTAssertNil(Money(minorUnits: 1, currency: "E1R", exponent: 2))
        XCTAssertNil(Money(minorUnits: 1, currency: "EUR", exponent: -1))
        XCTAssertNil(Money(minorUnits: 1, currency: "EUR", exponent: 5))
    }

    func testMoneyAddsOnlyTheSameCurrencyAndExponent() throws {
        let ten = try XCTUnwrap(Money(minorUnits: 1000, currency: "EUR", exponent: 2))
        let four = try XCTUnwrap(Money(minorUnits: 400, currency: "EUR", exponent: 2))
        XCTAssertEqual(ten + four, Money(minorUnits: 1400, currency: "EUR", exponent: 2))
        XCTAssertNil(ten + (try XCTUnwrap(Money(minorUnits: 400, currency: "USD", exponent: 2))))
        XCTAssertNil(ten + (try XCTUnwrap(Money(minorUnits: 4, currency: "EUR", exponent: 0))))
    }

    /// A hand-edited or corrupted file cannot smuggle in a negative amount:
    /// decoding goes through the same checks as the initialiser.
    func testMoneyDecodingAppliesTheSameChecks() throws {
        let good = try JSONDecoder().decode(Money.self, from: Data(#"{"minorUnits":1000,"currency":"EUR","exponent":2}"#.utf8))
        XCTAssertEqual(good, Money(minorUnits: 1000, currency: "EUR", exponent: 2))
        XCTAssertThrowsError(try JSONDecoder().decode(Money.self, from: Data(#"{"minorUnits":-5,"currency":"EUR","exponent":2}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(Money.self, from: Data(#"{"minorUnits":5,"currency":"EUR","exponent":9}"#.utf8)))
    }

    // MARK: UsageCredits on the snapshot

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    static func euros(_ cents: Int64) -> Money { Money(minorUnits: cents, currency: "EUR", exponent: 2)! }

    static func credits(at: Date, grants: [UsageCreditGrant]? = nil, complete: Bool = true) -> UsageCredits {
        UsageCredits(
            fetchedAt: at,
            balance: euros(1000),
            grants: grants ?? [UsageCreditGrant(id: "promo-1", kind: .promotional, remaining: euros(1000), granted: euros(1000), expiresAt: at.addingTimeInterval(200 * 86_400))],
            complete: complete
        )
    }

    private func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
    private func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }

    func testSnapshotRoundTripsCreditsAndTheSwitch() throws {
        let snapshot = UsageSnapshot(accountID: UUID(), fetchedAt: t0, fiveHour: nil, weekly: nil,
                                     usageCredits: Self.credits(at: t0), usageCreditsEnabled: false)
        let decoded = try decoder().decode(UsageSnapshot.self, from: encoder().encode(snapshot))
        XCTAssertEqual(decoded.usageCredits, Self.credits(at: t0))
        XCTAssertEqual(decoded.usageCreditsEnabled, false)
    }

    func testSnapshotFromAnOlderVersionHasNoCredits() throws {
        let json = #"{"accountID":"6A1C43E2-7B1D-4F0B-9D59-0D4B8E1E2C11","fetchedAt":"2026-09-30T10:00:00Z"}"#
        let decoded = try decoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(decoded.usageCredits)
        XCTAssertNil(decoded.usageCreditsEnabled)
    }

    /// A malformed value costs only itself, never the account's snapshot.
    func testMalformedCreditsNeverCostTheSnapshot() throws {
        let json = #"{"accountID":"6A1C43E2-7B1D-4F0B-9D59-0D4B8E1E2C11","fetchedAt":"2026-09-30T10:00:00Z","usageCredits":42,"usageCreditsEnabled":"yes"}"#
        let decoded = try decoder().decode(UsageSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.fetchedAt, ISO8601DateFormatter().date(from: "2026-09-30T10:00:00Z"))
        XCTAssertNil(decoded.usageCredits)
        XCTAssertNil(decoded.usageCreditsEnabled)
    }

    /// Every `replacing…` rebuilds the whole snapshot; none may drop a field.
    func testEveryReplacingHelperKeepsTheOtherFields() {
        let resets = ResetCredits(fetchedAt: t0, items: [ResetCredit(id: "r", title: nil, count: 1, expiresAt: t0.addingTimeInterval(9_000), usableNow: true)], complete: true)
        let full = UsageSnapshot(
            accountID: UUID(), fetchedAt: t0,
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.5, resetsAt: t0),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.4, resetsAt: t0),
            modelWeekly: UsageWindow(kind: .modelWeekly, remainingFraction: 0.3, resetsAt: t0, label: "Fable"),
            organizationID: "org-1", resetCredits: resets,
            planDetection: nil,
            usageCredits: Self.credits(at: t0), usageCreditsEnabled: true
        )
        XCTAssertEqual(full.replacingResetCredits(resets), full)
        XCTAssertEqual(full.replacingUsageCredits(Self.credits(at: t0)), full)
        XCTAssertEqual(full.replacingUsageCreditsEnabled(true), full)
        XCTAssertNil(full.replacingUsageCredits(nil).usageCredits)
        XCTAssertEqual(full.replacingUsageCredits(nil).resetCredits, resets)
        XCTAssertEqual(full.replacingUsageCreditsEnabled(false).usageCredits, Self.credits(at: t0))
        XCTAssertEqual(full.replacingResetCredits(nil).usageCreditsEnabled, true)
        XCTAssertEqual(full.replacingResetCredits(nil).organizationID, "org-1")
    }

    func testUnexpiredGrantsDropSpentAndExpiredOnes() {
        let grants = [
            UsageCreditGrant(id: "a", kind: .promotional, remaining: Self.euros(500), granted: Self.euros(500), expiresAt: t0.addingTimeInterval(60)),
            UsageCreditGrant(id: "b", kind: .purchased, remaining: Self.euros(500), granted: Self.euros(900), expiresAt: nil),
            UsageCreditGrant(id: "c", kind: .promotional, remaining: Self.euros(0), granted: Self.euros(500), expiresAt: t0.addingTimeInterval(9_000)),
        ]
        let credits = Self.credits(at: t0, grants: grants)
        XCTAssertEqual(credits.grants(unexpiredAt: t0).map(\.id), ["a", "b"])
        XCTAssertEqual(credits.grants(unexpiredAt: t0.addingTimeInterval(60)).map(\.id), ["b"], "expired at its own instant")
    }
}

