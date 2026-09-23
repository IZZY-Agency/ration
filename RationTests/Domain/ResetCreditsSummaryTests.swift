import XCTest
@testable import Ration

final class ResetCreditsSummaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private func c(_ id: String, _ inSec: TimeInterval, count: Int = 1, usable: Bool? = true) -> ResetCredit {
        ResetCredit(id: id, title: nil, count: count, expiresAt: now.addingTimeInterval(inSec), usableNow: usable)
    }
    private func list(_ items: [ResetCredit]) -> ResetCredits { ResetCredits(fetchedAt: now, items: items, complete: true) }

    func testNilWhenNothingUnexpired() {
        XCTAssertNil(ResetCreditsSummary.make(credits: nil, leadDays: 1, now: now))
        XCTAssertNil(ResetCreditsSummary.make(credits: list([c("a", -1)]), leadDays: 1, now: now))
    }

    func testSumsCountsAndPicksSoonest() throws {
        let s = try XCTUnwrap(ResetCreditsSummary.make(credits: list([c("a", 20 * 86_400, count: 2), c("b", 10 * 86_400)]), leadDays: 1, now: now))
        XCTAssertEqual(s.totalCount, 3)
        XCTAssertEqual(s.soonestExpiry, now.addingTimeInterval(10 * 86_400))
        XCTAssertFalse(s.withinLeadWindow)
        XCTAssertTrue(s.text(now: now).hasPrefix("↻ 3 resets · next expires "))
    }

    func testLeadWindowUsesRelativeText() throws {
        let s = try XCTUnwrap(ResetCreditsSummary.make(credits: list([c("a", 18 * 3600)]), leadDays: 1, now: now))
        XCTAssertTrue(s.withinLeadWindow)
        XCTAssertTrue(s.text(now: now).hasPrefix("↻ 1 reset · expires in "))
    }

    func testNotUsableOnlyWhenNoneUsable() throws {
        XCTAssertTrue(try XCTUnwrap(ResetCreditsSummary.make(credits: list([c("a", 86_400 * 5, usable: false)]), leadDays: 1, now: now)).noneUsable)
        XCTAssertFalse(try XCTUnwrap(ResetCreditsSummary.make(credits: list([c("a", 86_400 * 5, usable: false), c("b", 86_400 * 5, usable: nil)]), leadDays: 1, now: now)).noneUsable)
        let text = try XCTUnwrap(ResetCreditsSummary.make(credits: list([c("a", 86_400 * 5, usable: false)]), leadDays: 1, now: now)).text(now: now)
        XCTAssertTrue(text.hasSuffix(" · not usable yet"))
    }
}
