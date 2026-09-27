import XCTest
@testable import Ration

final class AlertMessageBudgetTests: XCTestCase {
    private let en = Locale(identifier: "en")
    private let fetched = ISO8601DateFormatter().date(from: "2026-09-27T12:05:00Z")!
    private func event(lowerBound: Bool = false, tier: AlertTier = .warning, percent: Int = 75) -> AlertEvent {
        .budgetThreshold(orgID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!, monthKey: "2026-09", tier: tier, percent: percent, spentCents: 46_820, budgetCents: 60_000, isLowerBound: lowerBound, reportFetchedAt: fetched)
    }

    func testPlainCopyNamesLabelThresholdAmountsAndAsOf() {
        let text = AlertMessage.text(for: event(), accountLabel: "IZZY", locale: en, now: fetched.addingTimeInterval(600))
        XCTAssertTrue(text.title.contains("IZZY"), text.title)
        XCTAssertTrue(text.title.contains("75"), text.title)
        XCTAssertTrue(text.body.contains("$468.20"), text.body)
        XCTAssertTrue(text.body.contains("$600"), text.body)
        XCTAssertTrue(text.body.contains(AlertMessage.asOfText(fetched, now: fetched.addingTimeInterval(600), locale: en)), text.body)
    }

    func testLowerBoundCopySaysAtLeastAndPriorityTier() {
        let body = AlertMessage.text(for: event(lowerBound: true), accountLabel: "IZZY", locale: en, now: fetched).body
        XCTAssertTrue(body.lowercased().contains("at least"), body)
        XCTAssertTrue(body.contains("Priority Tier"), body)
    }

    func testRedactedCopyHasNoLabelOrNumbers() {
        let text = AlertMessage.text(for: event(), accountLabel: "IZZY", redacted: true, locale: en)
        XCTAssertFalse(text.body.contains("IZZY"))
        XCTAssertFalse(text.body.contains("$"))
        XCTAssertEqual(text.title, "Ration")
    }

    func testIdUsesOnlyEventValues() {
        let id = AlertMessage.id(for: event(tier: .critical, percent: 90), accountID: UUID(uuidString: "11111111-1111-4111-8111-111111111111")!)
        XCTAssertEqual(id, "11111111-1111-4111-8111-111111111111.budget.2026-09.critical")
    }

    func testChannelKey() {
        XCTAssertEqual(AlertChannelKey.forEvent(event(), provider: .claude), "api.budgets")
    }

    func testAsOfShowsTheDateWhenNotToday() {
        let old = AlertMessage.asOfText(fetched, now: fetched.addingTimeInterval(3 * 86_400), locale: en, timeZone: TimeZone(identifier: "UTC")!)
        let today = AlertMessage.asOfText(fetched, now: fetched.addingTimeInterval(60), locale: en, timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertNotEqual(old, today)
        XCTAssertTrue(old.contains("Sep"), old)
    }
}
