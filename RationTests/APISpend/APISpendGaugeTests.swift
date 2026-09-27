import XCTest
@testable import Ration

final class APISpendGaugeTests: APISpendModelTestCase {
    func testGaugeOnlyWithBudgetAndCurrentReport() async throws {
        let id = try await seedOrg(budget: 60_000)
        let model = makeModel()
        await model.start()
        XCTAssertTrue(model.gauges(displaysRemaining: false, now: now).isEmpty)
        model.injectSnapshotForTesting(id, APISpendSnapshot(cost: costReport(month: UTCMonth(containing: now), cents: "30000", fetchedAt: now)))
        let gauge = try XCTUnwrap(model.gauges(displaysRemaining: false, now: now).first)
        XCTAssertEqual(gauge.source, .api(.anthropic))
        XCTAssertEqual(gauge.fraction, 0.5, accuracy: 0.0001)
        XCTAssertNil(gauge.windowKind)
        XCTAssertEqual(model.gauges(displaysRemaining: true, now: now).first?.fraction ?? -1, 0.5, accuracy: 0.0001)
        model.setBudget(id, cents: nil)
        XCTAssertTrue(model.gauges(displaysRemaining: false, now: now).isEmpty)
    }

    func testOldMonthReportAndPausedOrgHaveNoGauge() async throws {
        let id = try await seedOrg(budget: 60_000)
        let model = makeModel()
        await model.start()
        model.injectSnapshotForTesting(id, APISpendSnapshot(cost: costReport(month: UTCMonth(year: 2026, month: 8), cents: "30000", fetchedAt: now.addingTimeInterval(-40 * 86_400))))
        XCTAssertTrue(model.gauges(displaysRemaining: false, now: now).isEmpty)
        model.injectSnapshotForTesting(id, APISpendSnapshot(cost: costReport(month: UTCMonth(containing: now), cents: "30000", fetchedAt: now)))
        await model.setPaused(id, true)
        XCTAssertTrue(model.gauges(displaysRemaining: false, now: now).isEmpty)
    }
}
