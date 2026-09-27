import XCTest
@testable import Ration

final class APISpendCardTextTests: XCTestCase {
    private let en = Locale(identifier: "en")
    private let now = ISO8601DateFormatter().date(from: "2026-09-27T17:05:00Z")!
    private func presentation(budget: Int?, cents: String, coverage: PriorityCoverage? = nil, oldMonth: Bool = false, error: APISpendError? = nil) -> APIOrgPresentation {
        let month = oldMonth ? UTCMonth(year: 2026, month: 8) : UTCMonth(containing: now)
        let report = costReport(month: month, cents: cents, fetchedAt: oldMonth ? month.start : now)
        let org = APIOrgRecord(id: UUID(), vendor: .anthropic, vendorOrgID: "o", label: "IZZY", monthlyBudgetCents: budget, isPaused: false, displayOrder: 0, createdAt: now)
        return APIOrgPresentation(org: org, cost: report, tokens: nil, coverage: coverage, costError: error, tokenError: nil, isStale: false, isOldMonth: oldMonth,
                                  tier: budget.flatMap { APIBudgetPolicy.tier(monthToDateCents: report.monthToDateCents, budgetCents: $0, thresholds: .default) })
    }

    func testWithBudget() {
        let text = APISpendCardText.text(for: presentation(budget: 60_000, cents: "46820"), thresholds: .default, now: now, locale: en)
        XCTAssertEqual(text.headline, "$468.20")
        XCTAssertEqual(text.budgetSuffix, "/ $600")
        XCTAssertTrue(text.caption.hasPrefix("78"), text.caption)
        XCTAssertEqual(text.meterTier, .warning)           // configured 75/90, not UsageColorTier's 50/75
        XCTAssertEqual(text.meterFraction ?? -1, 0.7803, accuracy: 0.001)
    }

    func testBelowWarningHasNoTier() {
        XCTAssertNil(APISpendCardText.text(for: presentation(budget: 60_000, cents: "36000"), thresholds: .default, now: now, locale: en).meterTier)
    }

    func testOverBudgetShowsTheRealPercentAndAFullMeter() {
        let text = APISpendCardText.text(for: presentation(budget: 60_000, cents: "67200"), thresholds: .default, now: now, locale: en)
        XCTAssertTrue(text.caption.hasPrefix("112"), text.caption)
        XCTAssertEqual(text.meterFraction, 1)
        XCTAssertEqual(text.meterTier, .critical)
    }

    func testWithoutBudgetHasNoMeter() {
        let text = APISpendCardText.text(for: presentation(budget: nil, cents: "205"), thresholds: .default, now: now, locale: en)
        XCTAssertNil(text.meterFraction)
        XCTAssertNil(text.budgetSuffix)
        XCTAssertTrue(text.caption.hasPrefix("this month"), text.caption)
    }

    func testPriorityPresentIsFlooredLowerBound() {
        let text = APISpendCardText.text(for: presentation(budget: 60_000, cents: "100.6", coverage: .present), thresholds: .default, now: now, locale: en)
        XCTAssertEqual(text.headline, "≥ $1.00")
        XCTAssertTrue(text.caption.contains("Priority Tier not included"), text.caption)
    }

    func testPriorityUnknownSaysNotChecked() {
        XCTAssertTrue(APISpendCardText.text(for: presentation(budget: 60_000, cents: "1", coverage: .unknown), thresholds: .default, now: now, locale: en).caption.contains("Priority Tier not checked"))
    }

    func testOldMonthShowsRefreshing() {
        let text = APISpendCardText.text(for: presentation(budget: 60_000, cents: "1", oldMonth: true), thresholds: .default, now: now, locale: en)
        XCTAssertEqual(text.headline, "—")
        XCTAssertEqual(text.caption, "New month — refreshing")
        XCTAssertNil(text.meterFraction)
    }

    /// No bucket for today (Anthropic): the month-to-date is through
    /// yesterday and the card says so instead of "today $0.00".
    func testWithoutTodaysBucketTheCaptionSaysThroughYesterday() {
        var p = presentation(budget: 60_000, cents: "46820")
        p = APIOrgPresentation(org: p.org, cost: p.cost?.with(coversToday: false), tokens: nil, coverage: nil, costError: nil, tokenError: nil,
                               isStale: false, isOldMonth: false, tier: p.tier)
        let caption = APISpendCardText.text(for: p, thresholds: .default, now: now, locale: en).caption
        XCTAssertTrue(caption.contains("through yesterday"), caption)
        XCTAssertFalse(caption.contains("today"), caption)
        let noBudget = APISpendCardText.text(for: APIOrgPresentation(org: APIOrgRecord(id: p.org.id, vendor: .anthropic, vendorOrgID: "o", label: "IZZY",
                                                                                        monthlyBudgetCents: nil, isPaused: false, displayOrder: 0, createdAt: now),
                                                                     cost: p.cost, tokens: nil, coverage: nil, costError: nil, tokenError: nil,
                                                                     isStale: false, isOldMonth: false, tier: nil),
                                             thresholds: .default, now: now, locale: en).caption
        XCTAssertTrue(noBudget.contains("through yesterday"), noBudget)
        let covered = APISpendCardText.text(for: presentation(budget: 60_000, cents: "46820"), thresholds: .default, now: now, locale: en).caption
        XCTAssertTrue(covered.contains("today $468.20"), "a report with today's bucket keeps today: \(covered)")
    }

    /// On the 1st no bucket can exist yet, and "through
    /// yesterday" would describe last month — the card says nothing is
    /// reported yet instead.
    func testFirstDayOfTheMonthSaysNothingReportedYet() {
        let october1 = ISO8601DateFormatter().date(from: "2026-10-01T09:00:00Z")!
        let month = UTCMonth(containing: october1)
        let empty = APICostReport(month: month, fetchedAt: october1, refreshStartedAt: october1, days: [], byModel: [],
                                  otherCharges: [], byLineItem: [], coversToday: false)
        let org = APIOrgRecord(id: UUID(), vendor: .anthropic, vendorOrgID: "o", label: "IZZY", monthlyBudgetCents: 60_000,
                               isPaused: false, displayOrder: 0, createdAt: october1)
        let p = APIOrgPresentation(org: org, cost: empty, tokens: nil, coverage: nil, costError: nil, tokenError: nil,
                                   isStale: false, isOldMonth: false, tier: nil)
        let caption = APISpendCardText.text(for: p, thresholds: .default, now: october1, locale: en).caption
        XCTAssertTrue(caption.contains("no costs reported yet"), caption)
        XCTAssertFalse(caption.contains("yesterday"), caption)
        let noBudget = APIOrgPresentation(org: APIOrgRecord(id: org.id, vendor: .anthropic, vendorOrgID: "o", label: "IZZY", monthlyBudgetCents: nil,
                                                            isPaused: false, displayOrder: 0, createdAt: october1),
                                          cost: empty, tokens: nil, coverage: nil, costError: nil, tokenError: nil, isStale: false, isOldMonth: false, tier: nil)
        XCTAssertTrue(APISpendCardText.text(for: noBudget, thresholds: .default, now: october1, locale: en).caption.contains("no costs reported yet"))
    }

    func testEmptyMonth() {
        let text = APISpendCardText.text(for: presentation(budget: 60_000, cents: "0"), thresholds: .default, now: now, locale: en)
        XCTAssertEqual(text.headline, "$0.00")
        XCTAssertNil(text.meterTier)
    }

    func testStateCopyAndVoiceOver() {
        XCTAssertEqual(APISpendStateCopy.text(for: .keyRejected, locale: en), "Key rejected. Replace it in Settings.")
        XCTAssertEqual(APISpendStateCopy.text(for: .transport, locale: en), ProviderError.transport.message(locale: en))
        let spoken = APISpendCardText.accessibilityDescription(for: presentation(budget: 60_000, cents: "46820"), thresholds: .default, now: now, locale: en)
        XCTAssertTrue(spoken.hasPrefix("IZZY, Anthropic API"), spoken)
        XCTAssertFalse(spoken.contains("3d 6h"), "the countdown is spoken in words")
    }
}
