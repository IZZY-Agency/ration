import XCTest
@testable import Ration

final class AccountDisplaySortTests: XCTestCase {
    private func pres(_ order: Int, _ provider: Provider, weeklyReset: Date?) -> AccountPresentation {
        let id = UUID()
        let account = AccountRecord(id: id, provider: provider, label: "L\(order)", webProfileID: UUID(), displayOrder: order, createdAt: Date(timeIntervalSince1970: 0))
        let snapshot = weeklyReset.map { r in
            UsageSnapshot(accountID: id, fetchedAt: Date(timeIntervalSince1970: 0), fiveHour: nil, weekly: UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: r))
        }
        return AccountPresentation(account: account, snapshot: snapshot, state: .current)
    }
    private func d(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }

    func testToggleOffPreservesInputOrder() {
        let input = [pres(0, .claude, weeklyReset: d(9000)), pres(1, .claude, weeklyReset: d(1000))]
        XCTAssertEqual(AccountDisplaySort.sorted(input, sortByWeeklyReset: false).map(\.id), input.map(\.id))
    }
    func testSoonestWeeklyResetFirstWithinProvider() {
        let late = pres(0, .claude, weeklyReset: d(9000))
        let soon = pres(1, .claude, weeklyReset: d(1000))
        XCTAssertEqual(AccountDisplaySort.sorted([late, soon], sortByWeeklyReset: true).map(\.id), [soon.id, late.id])
    }
    func testNilWeeklyResetSinksLastInGroup() {
        let none = pres(0, .claude, weeklyReset: nil)
        let soon = pres(1, .claude, weeklyReset: d(1000))
        XCTAssertEqual(AccountDisplaySort.sorted([none, soon], sortByWeeklyReset: true).map(\.id), [soon.id, none.id])
    }
    func testGroupedByProviderInAllCasesOrder() {
        let gpt = pres(0, .chatGPT, weeklyReset: d(500))
        let claude = pres(1, .claude, weeklyReset: d(9000))
        let sorted = AccountDisplaySort.sorted([gpt, claude], sortByWeeklyReset: true)
        XCTAssertEqual(sorted.map(\.account.provider), [.claude, .chatGPT]) // claude group first despite gpt's sooner reset
    }
    func testStableTieBreakByDisplayOrder() {
        let a = pres(0, .claude, weeklyReset: d(1000))
        let b = pres(1, .claude, weeklyReset: d(1000))
        XCTAssertEqual(AccountDisplaySort.sorted([b, a], sortByWeeklyReset: true).map(\.id), [a.id, b.id]) // equal reset → displayOrder
    }

    // MARK: Soonest own-kind sort

    /// Each account is ranked by the soonest reset among ITS OWN kinds, so a
    /// Claude 5h reset can legitimately order ahead of its weekly one.
    func testAccountsRankOnSoonestOwnKindNotWeeklySpecifically() {
        let id = UUID()
        let account = AccountRecord(id: id, provider: .claude, label: "C", webProfileID: UUID(),
                                    displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0))
        // Weekly is far out, but the 5h window resets very soon.
        let snap = UsageSnapshot(
            accountID: id, fetchedAt: Date(timeIntervalSince1970: 0),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.5, resetsAt: d(100)),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: d(9000)))
        let fiveHourSoon = AccountPresentation(account: account, snapshot: snap, state: .current)
        let weeklyMid = pres(1, .claude, weeklyReset: d(500))
        XCTAssertEqual(
            AccountDisplaySort.sorted([weeklyMid, fiveHourSoon], sortByWeeklyReset: true).map(\.id),
            [fiveHourSoon.id, weeklyMid.id])
    }
}
