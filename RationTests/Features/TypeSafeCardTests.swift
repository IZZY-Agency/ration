import XCTest
@testable import Ration

@MainActor
final class TypeSafeCardTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-09-30T15:00:00Z")!
    private let nb = "\u{00A0}"
    private func usd(_ cents: Int64) -> Money { Money(minorUnits: cents, currency: "USD", exponent: 2)! }
    private func day(_ iso: String, input: Int) -> TypeSafeDay {
        TypeSafeDay(day: ISO8601DateFormatter().date(from: iso + "T00:00:00Z")!, inputTokens: input, outputTokens: 0, requests: 1)
    }

    /// A live reading.
    private func snapshot(readAgo: TimeInterval = 0, freeExpiresIn: TimeInterval = 17 * 86_400, sameFetch: Bool = true, usageReadAgo: TimeInterval = 0) -> UsageSnapshot {
        let read = now.addingTimeInterval(-readAgo)
        let grants = [
            UsageCreditGrant(id: "free-1", kind: .free, remaining: usd(158), granted: usd(500), expiresAt: now.addingTimeInterval(freeExpiresIn)),
            UsageCreditGrant(id: "bought-1", kind: .purchased, remaining: usd(2500), granted: usd(2500), expiresAt: ISO8601DateFormatter().date(from: "2027-09-29T00:00:00Z")),
        ]
        return UsageSnapshot(
            accountID: UUID(), fetchedAt: sameFetch ? read : read.addingTimeInterval(-60), fiveHour: nil, weekly: nil,
            usageCredits: UsageCredits(fetchedAt: read, balance: usd(2658), grants: grants, complete: true, readThisSession: true),
            typeSafeSpend: TypeSafeSpend(
                fetchedAt: read, cycleSpent: usd(341), cycleLabel: "September 2026",
                resetsAt: ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z"), autoRecharge: false
            ),
            typeSafeDailyUsage: TypeSafeDailyUsage(
                fetchedAt: now.addingTimeInterval(-usageReadAgo),
                days: [day("2026-08-31", input: 9_000_000), day("2026-09-29", input: 4_384_478), day("2026-09-30", input: 5_713_112)]
            )
        )
    }

    func testALiveCardInEveryLanguage() {
        let card = TypeSafeCard.make(snapshot: snapshot(), leadDays: 1, showsExpiry: true, now: now, locale: L10n.en)
        XCTAssertEqual(card.headline, "$26.58")
        XCTAssertEqual(card.caption, "$3.41 spent this cycle · resets in 9h", "whole hours: never minutes")
        XCTAssertNil(card.expiry, "17 days away is outside a 1-day warning window")
        XCTAssertFalse(card.isOld)
        XCTAssertEqual(card.spoken, "TypeSafe balance: $26.58 left. $3.41 spent this cycle · resets in 9h")
        let fr = TypeSafeCard.make(snapshot: snapshot(), leadDays: 1, showsExpiry: true, now: now, locale: L10n.fr)
        XCTAssertEqual(fr.headline, "26,58\(nb)$US")
        XCTAssertEqual(fr.caption, "3,41\(nb)$US dépensés ce cycle · réinitialisation dans 9\(nb)h")
        let uk = TypeSafeCard.make(snapshot: snapshot(), leadDays: 1, showsExpiry: true, now: now, locale: L10n.uk)
        XCTAssertTrue(uk.caption.hasPrefix("3,41\(nb)USD витрачено за цей цикл"), uk.caption)
    }

    /// Below the low-balance threshold the headline turns to the warning
    /// colour and VoiceOver says so; at or above it, nothing changes.
    func testBelowTheLowBalanceThreshold() {
        let low = TypeSafeCard.make(snapshot: snapshot(), leadDays: 1, showsExpiry: true, now: now, lowBalanceCents: 3_000, locale: L10n.en)
        XCTAssertTrue(low.isLow)
        XCTAssertEqual(low.spoken, "TypeSafe balance: $26.58 left. Below your $30.00 alert. $3.41 spent this cycle · resets in 9h")
        let fine = TypeSafeCard.make(snapshot: snapshot(), leadDays: 1, showsExpiry: true, now: now, lowBalanceCents: 2_658, locale: L10n.en)
        XCTAssertFalse(fine.isLow, "exactly on the threshold is not below it")
        XCTAssertFalse(TypeSafeCard.make(snapshot: snapshot(), leadDays: 1, showsExpiry: true, now: now, locale: L10n.en).isLow, "no threshold: off")
        let old = TypeSafeCard.make(snapshot: snapshot(readAgo: UsageEvidence.maxAge + 60), leadDays: 1, showsExpiry: true, now: now, lowBalanceCents: 3_000, locale: L10n.en)
        XCTAssertFalse(old.isLow, "an old balance is drawn faint, never said to be below the alert")
        XCTAssertFalse(old.spoken.contains("Below your"))
    }

    /// A monthly cycle counts down in whole hours or days, never minutes.
    func testTheCycleCountdownIsCoarse() {
        let later = now.addingTimeInterval(7 * 60)
        let card = TypeSafeCard.make(snapshot: snapshot(), leadDays: 1, showsExpiry: true, now: later, locale: L10n.en)
        XCTAssertEqual(card.caption, "$3.41 spent this cycle · resets in 8h")
        XCTAssertEqual(TypeSafeSettingsCopy.thisCycle(snapshot().typeSafeSpend!, now: later, locale: L10n.en), "$3.41 · September 2026 · resets in 8h")
    }

    func testBarsCoverTheCalendarMonthSoFar() {
        let bars = TypeSafeCard.cycleBars(snapshot().typeSafeDailyUsage, now: now)
        XCTAssertEqual(bars.count, 30, "Sep 1 … Sep 30")
        XCTAssertEqual(bars.last ?? 0, 5_713_112 * 0.042 / 1_000_000, accuracy: 1e-9)
        XCTAssertEqual(bars[28], 4_384_478 * 0.042 / 1_000_000, accuracy: 1e-9)
        XCTAssertEqual(bars.first, 0, "August's day is not in this cycle")
        XCTAssertEqual(TypeSafeCard.cycleBars(nil, now: now), [])
    }

    func testAGrantNearItsExpiryWarns() {
        let card = TypeSafeCard.make(snapshot: snapshot(freeExpiresIn: 18 * 3600), leadDays: 1, showsExpiry: true, now: now, locale: L10n.en)
        XCTAssertEqual(card.expiry, "$1.58 expires in 18h")
        XCTAssertEqual(TypeSafeCard.make(snapshot: snapshot(freeExpiresIn: 18 * 3600), leadDays: 1, showsExpiry: false, now: now).expiry, nil, "the Features switch hides it")
    }

    /// A carried reading (not this fetch's) shows its balance, never a warning.
    func testACarriedReadingNeverWarns() {
        let carried = snapshot(freeExpiresIn: 18 * 3600, sameFetch: false)
        XCTAssertFalse(carried.usageCreditsVerified)
        XCTAssertNil(TypeSafeCard.make(snapshot: carried, leadDays: 1, showsExpiry: true, now: now).expiry)
        XCTAssertTrue(snapshot().usageCreditsVerified, "read by the snapshot's own fetch")
    }

    func testEachPartFadesOnItsOwnAge() {
        let oldBilling = TypeSafeCard.make(snapshot: snapshot(readAgo: UsageEvidence.maxAge + 60), leadDays: 1, showsExpiry: true, now: now)
        XCTAssertTrue(oldBilling.isOld)
        XCTAssertTrue(oldBilling.captionIsOld, "the spend comes with the balance")
        XCTAssertFalse(oldBilling.barsAreOld)
        let oldUsage = TypeSafeCard.make(snapshot: snapshot(usageReadAgo: UsageEvidence.maxAge + 60), leadDays: 1, showsExpiry: true, now: now)
        XCTAssertFalse(oldUsage.isOld)
        XCTAssertTrue(oldUsage.barsAreOld)
    }

    /// On the 31st the answer's 30 days no longer reach the 1st: that day is
    /// unknown, not zero.
    func testDaysBeforeTheCoverageAreLeftOut() {
        let the31st = ISO8601DateFormatter().date(from: "2026-10-31T12:00:00Z")!
        let usage = TypeSafeDailyUsage(fetchedAt: the31st, days: [day("2026-10-31", input: 1_000_000)])
        let bars = TypeSafeCard.cycleBars(usage, now: the31st)
        XCTAssertEqual(bars.count, 30, "Oct 2 … Oct 31: Oct 1 is outside the coverage")
    }

    /// A billing miss on the first fetch still shows the day bars.
    func testUsageWithoutABalanceStillDraws() {
        let usageOnly = UsageSnapshot(accountID: UUID(), fetchedAt: now, fiveHour: nil, weekly: nil,
                                      typeSafeDailyUsage: TypeSafeDailyUsage(fetchedAt: now, days: [day("2026-09-30", input: 5_713_112)]))
        let card = TypeSafeCard.make(snapshot: usageOnly, leadDays: 1, showsExpiry: true, now: now)
        XCTAssertEqual(card.headline, "—")
        XCTAssertEqual(card.bars.count, 30)
        XCTAssertGreaterThan(card.bars.last ?? 0, 0)
    }

    func testNoReadingShowsADash() {
        let card = TypeSafeCard.make(snapshot: nil, leadDays: 1, showsExpiry: true, now: now)
        XCTAssertEqual(card.headline, "—")
        XCTAssertFalse(card.isAvailable)
    }

    // MARK: Settings

    func testSettingsCopy() {
        let spend = snapshot().typeSafeSpend!
        XCTAssertEqual(TypeSafeSettingsCopy.thisCycle(spend, now: now, locale: L10n.en), "$3.41 · September 2026 · resets in 9h")
        XCTAssertTrue(TypeSafeSettingsCopy.thisCycle(spend, now: now, locale: L10n.uk).contains("вересень 2026"), TypeSafeSettingsCopy.thisCycle(spend, now: now, locale: L10n.uk))
        XCTAssertTrue(TypeSafeSettingsCopy.thisCycle(spend, now: now, locale: L10n.fr).contains("septembre 2026"))
        XCTAssertEqual(TypeSafeSettingsCopy.autoRecharge(false, locale: L10n.fr), "Désactivée")
        let days = snapshot().typeSafeDailyUsage!.days
        XCTAssertEqual(TypeSafeSettingsCopy.last30Days(days, locale: L10n.en), "19.1M input tokens · 3 requests · ≈ $0.80")
        XCTAssertEqual(TypeSafeSettingsCopy.estimateNote(locale: L10n.en), "Estimated at $0.042 per million input tokens, as TypeSafe's console does; output is free.")
        XCTAssertEqual(TypeSafeSettingsCopy.creditsFootnote(locale: L10n.en), "Add funds or turn on auto-recharge on console.typesafe.ai. Ration only shows them.")
        XCTAssertEqual(SettingsCopy.usageCreditsKind(.free, locale: L10n.uk), "Безкоштовний кредит")
        XCTAssertFalse(TypeSafeSettingsCopy.last30Days(days, locale: L10n.uk).contains("акаунт"))
    }

    // MARK: Focus

    func testFocusShowsTheBalance() {
        XCTAssertEqual(FocusView.balanceText(usd(2658), locale: L10n.en), "$26.58 left")
        XCTAssertEqual(FocusView.spokenValue(.balance(usd(2658)), locale: L10n.en), "TypeSafe balance: $26.58 left.")
    }
}
