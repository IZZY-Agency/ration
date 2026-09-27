import XCTest
@testable import Ration

final class APIBudgetPolicyTests: XCTestCase {
    private let sep = UTCMonth(year: 2026, month: 9)
    private let oct = UTCMonth(year: 2026, month: 10)
    private func report(_ cents: String, month: UTCMonth? = nil) -> APICostReport {
        let m = month ?? sep
        return APICostReport(month: m, fetchedAt: m.start.addingTimeInterval(3_600), refreshStartedAt: m.start, days: [DayCost(dayStart: m.start, cents: Decimal(string: cents)!)], byModel: [], otherCharges: [], byLineItem: [])
    }

    func testTierComparesUnroundedCentsInclusively() {
        // 75 % of 60,001 ¢ = 45,000.75 ¢
        XCTAssertNil(APIBudgetPolicy.tier(monthToDateCents: Decimal(string: "45000.50")!, budgetCents: 60_001, thresholds: .default))
        XCTAssertEqual(APIBudgetPolicy.tier(monthToDateCents: Decimal(string: "45000.75")!, budgetCents: 60_001, thresholds: .default), .warning)
        XCTAssertEqual(APIBudgetPolicy.tier(monthToDateCents: 54_000, budgetCents: 60_000, thresholds: .default), .critical)
    }

    func testCrossingFiresOnceAndEscalates() {
        let first = APIBudgetPolicy.evaluate(report: report("46000"), budgetCents: 60_000, thresholds: .default, previous: BudgetAlertMemory(), prime: false)
        XCTAssertEqual(first.crossed, .warning)
        let again = APIBudgetPolicy.evaluate(report: report("47000"), budgetCents: 60_000, thresholds: .default, previous: first.next, prime: false)
        XCTAssertNil(again.crossed)
        let up = APIBudgetPolicy.evaluate(report: report("55000"), budgetCents: 60_000, thresholds: .default, previous: again.next, prime: false)
        XCTAssertEqual(up.crossed, .critical)
    }

    func testBurstCrossingBothThresholdsIsOneCriticalAlert() {
        let decision = APIBudgetPolicy.evaluate(report: report("59000"), budgetCents: 60_000, thresholds: .default, previous: BudgetAlertMemory(), prime: false)
        XCTAssertEqual(decision.crossed, .critical)
        XCTAssertEqual(decision.next.notifiedTier, .critical)
    }

    func testPrimeRecordsWithoutCrossing() {
        let decision = APIBudgetPolicy.evaluate(report: report("59000"), budgetCents: 60_000, thresholds: .default, previous: BudgetAlertMemory(), prime: true)
        XCTAssertNil(decision.crossed)
        XCTAssertEqual(decision.next.notifiedTier, .critical)
    }

    func testMonthChangeReArmsAndSignalsAdvance() {
        let sepMemory = BudgetAlertMemory(evaluatedMonthKey: "2026-09", notifiedTier: .critical, dismissedTier: .critical)
        let decision = APIBudgetPolicy.evaluate(report: report("46000", month: oct), budgetCents: 60_000, thresholds: .default, previous: sepMemory, prime: false)
        XCTAssertEqual(decision.crossed, .warning)
        XCTAssertTrue(decision.monthAdvanced)
        XCTAssertEqual(decision.next.evaluatedMonthKey, "2026-10")
        XCTAssertNil(decision.next.dismissedTier)
    }

    func testFirstEverEvaluationIsNotAMonthAdvance() {
        XCTAssertFalse(APIBudgetPolicy.evaluate(report: report("1"), budgetCents: 60_000, thresholds: .default, previous: BudgetAlertMemory(), prime: false).monthAdvanced)
    }

    func testRaisingTheThresholdCannotRepostAPassedTier() {
        let memory = BudgetAlertMemory(evaluatedMonthKey: "2026-09", notifiedTier: .warning, dismissedTier: nil)
        let decision = APIBudgetPolicy.evaluate(report: report("46000"), budgetCents: 60_000, thresholds: ThresholdPair(warningPercent: 80, criticalPercent: 95), previous: memory, prime: false)
        XCTAssertNil(decision.crossed)
        XCTAssertEqual(decision.next.notifiedTier, .warning)
    }
}
