import XCTest
@testable import Ration

final class BillingCycleSectionModelTests: XCTestCase {
    private func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
    private func at(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
        utc().date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    private func account(renewalDay: Int?, label: String = "Work") -> AccountRecord {
        AccountRecord(id: UUID(), provider: .claude, label: label, webProfileID: UUID(),
                      displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0),
                      billingRenewalDay: renewalDay)
    }
    private func hours(_ day: Int, count: Int, consumed: Double, minRemaining: Double) -> [UsageHourlyBucket] {
        (0..<count).map { UsageHourlyBucket(hourStart: at(2026, 7, day, $0), tzOffsetSeconds: 0,
                                            consumed: consumed, minRemaining: minRemaining, sampleCount: 1) }
    }

    private func acct(_ provider: Provider, renewalDay: Int? = nil, label: String = "A") -> AccountRecord {
        AccountRecord(id: UUID(), provider: provider, label: label, webProfileID: UUID(),
                      displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0),
                      billingRenewalDay: renewalDay)
    }

    // MARK: Cursor eligibility (v1 exclusion)

    /// Cursor reports cycle utilisation natively on its account card — its two
    /// monthly pools ARE the cycle view. This window exists to *reconstruct*
    /// that number for providers that only expose rolling windows, so including
    /// Cursor would re-derive, worse, a number already in hand. Excluded in v1.
    func testCursorIsNotEligibleForTheBillingCycleWindow() {
        XCTAssertFalse(BillingCycleEligibility.supports(.cursor))
        XCTAssertTrue(BillingCycleEligibility.supports(.claude))
        XCTAssertTrue(BillingCycleEligibility.supports(.chatGPT))
    }

    func testEligibleFilterDropsOnlyCursorAndPreservesOrder() {
        let claude = acct(.claude, label: "C")
        let cursor = acct(.cursor, label: "Cu")
        let gpt = acct(.chatGPT, label: "G")
        let filtered = BillingCycleEligibility.eligible([claude, cursor, gpt])
        XCTAssertEqual(filtered.map(\.label), ["C", "G"])
    }

    /// A Cursor account carrying a renewal day — imported, or set before the
    /// control was hidden — is RETAINED but ignored. The filter is absolute;
    /// nothing silently deletes user data.
    func testCursorWithStaleRenewalDayIsStillExcludedAndValueUntouched() {
        let cursor = acct(.cursor, renewalDay: 14)
        XCTAssertTrue(BillingCycleEligibility.eligible([cursor]).isEmpty)
        XCTAssertEqual(cursor.billingRenewalDay, 14, "the stored value must not be mutated by exclusion")
    }

    // MARK: Presentation state

    func testNoAccountsAtAllIsDistinctFromNoEligibleAccounts() {
        XCTAssertEqual(BillingCycleEligibility.presentation(accounts: [], cards: []), .noAccounts)
        // A Cursor-only install has accounts but none eligible — it must get its
        // own explanation, not a blank scroll view and not "No accounts".
        XCTAssertEqual(
            BillingCycleEligibility.presentation(accounts: [acct(.cursor)], cards: []),
            .noEligibleAccounts)
    }

    func testAllEligibleAccountsLackingRenewalDayKeepsTheGlobalCTA() {
        let cards: [BillingCycleCard] = [
            .noRenewalDay(id: UUID(), label: "C", provider: .claude),
            .noRenewalDay(id: UUID(), label: "G", provider: .chatGPT),
        ]
        XCTAssertEqual(
            BillingCycleEligibility.presentation(accounts: [acct(.claude), acct(.chatGPT)], cards: cards),
            .noRenewalDaysSet,
            "the global CTA must survive the eligibility filter — a mixed state shows per-card CTAs instead")
    }

    func testCursorPresenceDoesNotSuppressTheGlobalCTAForEligibleAccounts() {
        let cards: [BillingCycleCard] = [.noRenewalDay(id: UUID(), label: "C", provider: .claude)]
        XCTAssertEqual(
            BillingCycleEligibility.presentation(accounts: [acct(.claude), acct(.cursor)], cards: cards),
            .noRenewalDaysSet)
    }

    func testMixedRenewalStateShowsCards() {
        let cycle = BillingCycle.current(renewalDay: 1, now: at(2026, 7, 21, 0), calendar: utc())
        let cards: [BillingCycleCard] = [
            .noRenewalDay(id: UUID(), label: "C", provider: .claude),
            .tracked(id: UUID(), label: "G", provider: .chatGPT, cycle: cycle,
                     summary: CycleUtilizationSummary(
                        windowKind: .weekly, capacityUtilization: 0.5, consumedAllowances: 1,
                        daysUsed: 1, atCapDays: 0, observedHours: 24, elapsedHours: 24),
                     fable: nil),
        ]
        XCTAssertEqual(
            BillingCycleEligibility.presentation(accounts: [acct(.claude), acct(.chatGPT)], cards: cards),
            .cards)
    }

    func testNoRenewalDayProducesPromptCard() {
        let card = BillingCycleSectionModel.card(
            account: account(renewalDay: nil), weekly: [], fiveHour: [],
            now: at(2026, 7, 21, 0), calendar: utc())
        guard case .noRenewalDay = card else { return XCTFail("expected noRenewalDay") }
    }

    func testTrackedCardCarriesSummary() {
        // 48 observed hours (2 full days) — above the weekly 42h sufficiency floor
        // (Change 1); the old 20-hour fixture is no longer sufficient.
        let acct = account(renewalDay: 1)
        let weekly = hours(1, count: 24, consumed: 0.05, minRemaining: 0.8) + hours(2, count: 24, consumed: 0.05, minRemaining: 0.8)
        let card = BillingCycleSectionModel.card(
            account: acct, weekly: weekly, fiveHour: [], now: at(2026, 7, 3, 0), calendar: utc())
        guard case let .tracked(_, _, _, _, summary, _) = card else { return XCTFail("expected tracked") }
        XCTAssertEqual(summary.windowKind, .weekly)
        XCTAssertTrue(summary.isSufficient)
    }

    func testSelectsWeeklyWhenWeeklyCovered() {
        // Both windows given ≥42 observed hours so weekly stays sufficient (Change 1)
        // and is selected because `selectWindow` now checks `isSufficient`, not raw
        // coverage (Change 2).
        let acct = account(renewalDay: 1)
        let weekly = hours(1, count: 24, consumed: 0.05, minRemaining: 0.8) + hours(2, count: 24, consumed: 0.05, minRemaining: 0.8)   // sufficient
        let fiveHour = hours(1, count: 24, consumed: 0.3, minRemaining: 0.3) + hours(2, count: 24, consumed: 0.3, minRemaining: 0.3)    // also sufficient
        let card = BillingCycleSectionModel.card(
            account: acct, weekly: weekly, fiveHour: fiveHour, now: at(2026, 7, 3, 0), calendar: utc())
        guard case let .tracked(_, _, _, _, summary, _) = card else { return XCTFail("expected tracked") }
        XCTAssertEqual(summary.windowKind, .weekly)
    }

    func testFallsBackToFiveHourWhenWeeklyCoverageLow() {
        let acct = account(renewalDay: 1)
        // now = day1 20:00 → 20 elapsed hours. Weekly has only 5 observed (coverage 0.25).
        let weekly = hours(1, count: 5, consumed: 0.02, minRemaining: 0.9)
        let fiveHour = hours(1, count: 20, consumed: 0.2, minRemaining: 0.5)
        let card = BillingCycleSectionModel.card(
            account: acct, weekly: weekly, fiveHour: fiveHour, now: at(2026, 7, 1, 20), calendar: utc())
        guard case let .tracked(_, _, _, _, summary, _) = card else { return XCTFail("expected tracked") }
        XCTAssertEqual(summary.windowKind, .fiveHour)
    }

    // MARK: - selectWindow sufficiency (Change 2)

    func testSelectWindowPrefersSufficientFiveHourWhenWeeklyInsufficient() {
        // Weekly: coverage exactly 0.5 but only 20 observed hours (< the 42h weekly
        // floor) → insufficient. 5h: coverage 0.75 and 15 observed hours (≥ the 12h
        // 5h floor) → sufficient. An insufficient weekly must not suppress it.
        let weekly = CycleUtilizationSummary(
            windowKind: .weekly, capacityUtilization: 2.0, consumedAllowances: 1.0,
            daysUsed: 3, atCapDays: 0, observedHours: 20, elapsedHours: 40)
        let fiveHour = CycleUtilizationSummary(
            windowKind: .fiveHour, capacityUtilization: 1.0, consumedAllowances: 0.5,
            daysUsed: 2, atCapDays: 0, observedHours: 15, elapsedHours: 20)
        XCTAssertFalse(weekly.isSufficient)
        XCTAssertTrue(fiveHour.isSufficient)
        let selected = BillingCycleSectionModel.selectWindow(weekly: weekly, fiveHour: fiveHour)
        XCTAssertEqual(selected.windowKind, .fiveHour)
    }

    func testSelectWindowFallsBackToBetterCoveredWhenBothInsufficient() {
        // Neither window clears its sufficiency gate — weekly coverage 0.25 (10/40),
        // 5h coverage 0.15 (3/20). The card's own honesty gate still renders "Not
        // enough data yet"; selectWindow's job here is just to prefer the
        // better-covered summary so the displayed shortfall is the smaller one.
        let weekly = CycleUtilizationSummary(
            windowKind: .weekly, capacityUtilization: 0.5, consumedAllowances: 0.1,
            daysUsed: 1, atCapDays: 0, observedHours: 10, elapsedHours: 40)
        let fiveHour = CycleUtilizationSummary(
            windowKind: .fiveHour, capacityUtilization: 0.2, consumedAllowances: 0.05,
            daysUsed: 1, atCapDays: 0, observedHours: 3, elapsedHours: 20)
        XCTAssertFalse(weekly.isSufficient)
        XCTAssertFalse(fiveHour.isSufficient)
        let selected = BillingCycleSectionModel.selectWindow(weekly: weekly, fiveHour: fiveHour)
        XCTAssertEqual(selected.windowKind, .weekly, "weekly has the higher coverage fraction (0.25 vs 0.15)")
    }

    // MARK: - Fable secondary

    func testTrackedCardIncludesFableSecondaryWhenModelRollupsPresent() {
        // Weekly (headline) AND modelWeekly (Fable) both get 48 observed hours —
        // above the 42h weekly/modelWeekly sufficiency floor. The headline must
        // remain the all-usage weekly; Fable is only a secondary. `fablePresent`
        // (the current snapshot's modelWeekly presence) is what gates visibility,
        // not the rollups themselves.
        let acct = account(renewalDay: 1)
        let weekly = hours(1, count: 24, consumed: 0.05, minRemaining: 0.8) + hours(2, count: 24, consumed: 0.05, minRemaining: 0.8)
        let modelWeekly = hours(1, count: 24, consumed: 0.1, minRemaining: 0.6) + hours(2, count: 24, consumed: 0.1, minRemaining: 0.6)
        let card = BillingCycleSectionModel.card(
            account: acct, weekly: weekly, fiveHour: [], modelWeekly: modelWeekly,
            fablePresent: true, fableLabel: "Fable",
            now: at(2026, 7, 3, 0), calendar: utc())
        guard case let .tracked(_, _, _, _, summary, fable) = card else { return XCTFail("expected tracked") }
        XCTAssertEqual(summary.windowKind, .weekly, "headline must stay the all-usage weekly, never Fable")
        guard let fable else { return XCTFail("expected a non-nil fable secondary") }
        XCTAssertEqual(fable.label, "Fable")
        XCTAssertEqual(fable.summary?.windowKind, .modelWeekly)
        XCTAssertTrue(fable.summary?.isSufficient == true)
    }

    func testNoFableSecondaryWhenNoModelRollups() {
        // fablePresent=false (no current-snapshot modelWeekly window at all —
        // never a Fable/Max account) → fable secondary nil; the headline is
        // unaffected.
        let acct = account(renewalDay: 1)
        let weekly = hours(1, count: 24, consumed: 0.05, minRemaining: 0.8) + hours(2, count: 24, consumed: 0.05, minRemaining: 0.8)
        let card = BillingCycleSectionModel.card(
            account: acct, weekly: weekly, fiveHour: [], modelWeekly: [],
            now: at(2026, 7, 3, 0), calendar: utc())
        guard case let .tracked(_, _, _, _, summary, fable) = card else { return XCTFail("expected tracked") }
        XCTAssertEqual(summary.windowKind, .weekly)
        XCTAssertNil(fable)
    }

    // MARK: - Fable presence gates on the CURRENT snapshot, not retained rollups (Fix 1)

    func testFableSecondaryHiddenWhenSnapshotAbsentDespiteRollups() {
        // Max→non-Max downgrade: modelWeekly rollups are retained forever,
        // but the CURRENT snapshot no longer carries a modelWeekly window
        // (fablePresent=false). The stale rollups must NOT resurrect a Fable
        // secondary.
        let acct = account(renewalDay: 1)
        let weekly = hours(1, count: 24, consumed: 0.05, minRemaining: 0.8) + hours(2, count: 24, consumed: 0.05, minRemaining: 0.8)
        let modelWeekly = hours(1, count: 24, consumed: 0.1, minRemaining: 0.6) + hours(2, count: 24, consumed: 0.1, minRemaining: 0.6)
        let card = BillingCycleSectionModel.card(
            account: acct, weekly: weekly, fiveHour: [], modelWeekly: modelWeekly,
            fablePresent: false, fableLabel: nil,
            now: at(2026, 7, 3, 0), calendar: utc())
        guard case let .tracked(_, _, _, _, _, fable) = card else { return XCTFail("expected tracked") }
        XCTAssertNil(fable, "stale rollups must not resurrect Fable once the current snapshot no longer carries modelWeekly")
    }

    func testFableSecondaryPresentButInsufficientShowsNoDataState() {
        // fablePresent=true (a fresh Max account: the current snapshot HAS a
        // modelWeekly window) but rollups haven't accrued past the sufficiency
        // floor yet. Fable must be present (non-nil) but with a nil summary —
        // "not enough data yet", never a fabricated percentage.
        let acct = account(renewalDay: 1)
        let weekly = hours(1, count: 24, consumed: 0.05, minRemaining: 0.8) + hours(2, count: 24, consumed: 0.05, minRemaining: 0.8)
        let modelWeekly = hours(1, count: 4, consumed: 0.01, minRemaining: 0.95) // far under the 42h floor
        let card = BillingCycleSectionModel.card(
            account: acct, weekly: weekly, fiveHour: [], modelWeekly: modelWeekly,
            fablePresent: true, fableLabel: "Fable",
            now: at(2026, 7, 3, 0), calendar: utc())
        guard case let .tracked(_, _, _, _, _, fable) = card else { return XCTFail("expected tracked") }
        guard let fable else { return XCTFail("expected a present-but-insufficient Fable secondary") }
        XCTAssertEqual(fable.label, "Fable")
        XCTAssertNil(fable.summary, "insufficient data must render as an absent summary, never a fabricated %")
    }

    func testFableSecondaryUsesApiLabel() {
        // The API-provided label (not a hardcoded "Fable") must be carried
        // through to the card.
        let acct = account(renewalDay: 1)
        let weekly = hours(1, count: 24, consumed: 0.05, minRemaining: 0.8) + hours(2, count: 24, consumed: 0.05, minRemaining: 0.8)
        let modelWeekly = hours(1, count: 24, consumed: 0.1, minRemaining: 0.6) + hours(2, count: 24, consumed: 0.1, minRemaining: 0.6)
        let card = BillingCycleSectionModel.card(
            account: acct, weekly: weekly, fiveHour: [], modelWeekly: modelWeekly,
            fablePresent: true, fableLabel: "Opus 4.6",
            now: at(2026, 7, 3, 0), calendar: utc())
        guard case let .tracked(_, _, _, _, _, fable) = card else { return XCTFail("expected tracked") }
        XCTAssertEqual(fable?.label, "Opus 4.6")
    }
}
