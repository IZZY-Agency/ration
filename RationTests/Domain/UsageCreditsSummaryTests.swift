import XCTest
@testable import Ration

final class UsageCreditsSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let nb = "\u{00A0}"

    private func euros(_ cents: Int64) -> Money { Money(minorUnits: cents, currency: "EUR", exponent: 2)! }

    private func grant(_ id: String, cents: Int64, expiresIn: TimeInterval?) -> UsageCreditGrant {
        UsageCreditGrant(id: id, kind: .promotional, remaining: euros(cents), granted: euros(cents),
                         expiresAt: expiresIn.map { now.addingTimeInterval($0) })
    }

    private func credits(balance: Int64 = 1000, grants: [UsageCreditGrant]? = nil, readAgo: TimeInterval = 30) -> UsageCredits {
        UsageCredits(fetchedAt: now.addingTimeInterval(-readAgo), balance: euros(balance),
                     grants: grants ?? [grant("promo", cents: balance, expiresIn: 200 * 86_400)], complete: true)
    }

    private func summary(_ credits: UsageCredits?, enabled: Bool? = true, leadDays: Int = 1) -> UsageCreditsSummary? {
        UsageCreditsSummary.make(credits: credits, enabled: enabled, leadDays: leadDays, now: now)
    }

    func testTheBalanceAlone() throws {
        let line = try XCTUnwrap(summary(credits()))
        XCTAssertEqual(line.text(now: now, locale: L10n.en), "Credits €10.00")
        XCTAssertNil(line.expiring)
        XCTAssertFalse(line.isOld)
        XCTAssertEqual(line.accessibilityText(now: now, locale: L10n.en), "Usage credits: €10.00.")
    }

    func testTheSwitchOffIsSaidOnlyWhenKnown() throws {
        XCTAssertEqual(try XCTUnwrap(summary(credits(), enabled: false)).text(now: now, locale: L10n.en), "Credits €10.00 · off")
        XCTAssertEqual(try XCTUnwrap(summary(credits(), enabled: nil)).text(now: now, locale: L10n.en), "Credits €10.00", "unknown is not off")
        XCTAssertEqual(try XCTUnwrap(summary(credits(), enabled: false)).accessibilityText(now: now, locale: L10n.en), "Usage credits: €10.00. Off on claude.ai.")
    }

    /// A live reading, in every language.
    func testTheVerifiedAccountInEveryLanguage() throws {
        let line = try XCTUnwrap(summary(credits(), enabled: false))
        XCTAssertEqual(line.text(now: now, locale: L10n.en), "Credits €10.00 · off")
        XCTAssertEqual(line.text(now: now, locale: L10n.fr), "Crédits 10,00\(nb)€ · désactivés")
        XCTAssertEqual(line.text(now: now, locale: L10n.uk), "Кредити 10,00\(nb)EUR · вимкнено")
        XCTAssertEqual(line.accessibilityText(now: now, locale: L10n.fr), "Crédits d’utilisation\(nb): 10,00\(nb)€. Désactivés sur claude.ai.")
    }

    func testTheWholeBalanceExpiring() throws {
        let line = try XCTUnwrap(summary(credits(grants: [grant("promo", cents: 1000, expiresIn: 18 * 3600)])))
        XCTAssertEqual(line.expiring, .init(amount: euros(1000), expiresAt: now.addingTimeInterval(18 * 3600), wholeBalance: true))
        XCTAssertEqual(line.text(now: now, locale: L10n.en), "Credits €10.00 · expires in 18h")
        XCTAssertEqual(line.accessibilityText(now: now, locale: L10n.en), "Usage credits: €10.00. They expire in 18 hours.")
    }

    func testPartOfTheBalanceExpiring() throws {
        let grants = [grant("soon", cents: 400, expiresIn: 18 * 3600), grant("later", cents: 600, expiresIn: 90 * 86_400)]
        let line = try XCTUnwrap(summary(credits(grants: grants), enabled: false))
        XCTAssertEqual(line.text(now: now, locale: L10n.en), "Credits €10.00 · off · €4.00 expires in 18h")
        XCTAssertEqual(line.text(now: now, locale: L10n.uk), "Кредити 10,00\(nb)EUR · вимкнено · 4,00\(nb)EUR спливає через 18\(nb)год")
    }

    func testSeveralGrantsInTheWindowAreSummed() throws {
        let grants = [grant("a", cents: 400, expiresIn: 18 * 3600), grant("b", cents: 300, expiresIn: 5 * 3600), grant("c", cents: 300, expiresIn: 90 * 86_400)]
        let line = try XCTUnwrap(summary(credits(grants: grants)))
        XCTAssertEqual(line.expiring?.amount, euros(700))
        XCTAssertEqual(line.expiring?.expiresAt, now.addingTimeInterval(5 * 3600), "the soonest")
        XCTAssertEqual(line.text(now: now, locale: L10n.en), "Credits €10.00 · €7.00 expires in 5h")
    }

    func testTheLeadTimeDecidesTheWindow() throws {
        let grants = [grant("promo", cents: 1000, expiresIn: 3 * 86_400)]
        XCTAssertNil(try XCTUnwrap(summary(credits(grants: grants), leadDays: 1)).expiring)
        XCTAssertNotNil(try XCTUnwrap(summary(credits(grants: grants), leadDays: 3)).expiring)
    }

    /// "Now" is the resets line's rule: under a second left.
    func testExpiringNow() throws {
        let line = try XCTUnwrap(summary(credits(grants: [grant("promo", cents: 1000, expiresIn: 0.5)])))
        XCTAssertEqual(line.text(now: now, locale: L10n.en), "Credits €10.00 · expires now")
        let soon = try XCTUnwrap(summary(credits(grants: [grant("promo", cents: 1000, expiresIn: 20)])))
        XCTAssertEqual(soon.text(now: now, locale: L10n.en), "Credits €10.00 · expires in <1h")
    }

    func testAnOldReadingFadesThenLeaves() throws {
        let old = try XCTUnwrap(summary(credits(readAgo: UsageEvidence.maxAge + 60)))
        XCTAssertTrue(old.isOld)
        XCTAssertTrue(old.accessibilityText(now: now, locale: L10n.en).hasPrefix("Usage credits: €10.00. Last read at "))
        XCTAssertFalse(try XCTUnwrap(summary(credits(readAgo: UsageEvidence.maxAge))).isOld)
        XCTAssertNotNil(summary(credits(readAgo: UsageCreditsSummary.hideAfter)))
        XCTAssertNil(summary(credits(readAgo: UsageCreditsSummary.hideAfter + 1)), "a day-old balance is not shown")
    }

    /// A reading not verified this session shows its balance, never an expiry.
    func testAnUnverifiedReadingNeverWarns() throws {
        let grants = [grant("promo", cents: 1000, expiresIn: 18 * 3600)]
        let line = try XCTUnwrap(UsageCreditsSummary.make(credits: credits(grants: grants), enabled: false, leadDays: 1, now: now, verified: false))
        XCTAssertNil(line.expiring)
        XCTAssertEqual(line.text(now: now, locale: L10n.en), "Credits €10.00 · off")
    }

    func testNothingToShow() {
        XCTAssertNil(summary(nil))
        XCTAssertNil(summary(credits(balance: 0, grants: [])))
    }
}
