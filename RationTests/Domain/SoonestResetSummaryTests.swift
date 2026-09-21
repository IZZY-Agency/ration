import XCTest
@testable import Ration

final class SoonestResetSummaryTests: XCTestCase {
    private func pres(_ label: String, five: Date?, weekly: Date?) -> AccountPresentation {
        let id = UUID()
        let account = AccountRecord(id: id, provider: .claude, label: label, webProfileID: UUID(), displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0))
        let snapshot = UsageSnapshot(
            accountID: id, fetchedAt: Date(timeIntervalSince1970: 0),
            fiveHour: five.map { UsageWindow(kind: .fiveHour, remainingFraction: 0.5, resetsAt: $0) },
            weekly: weekly.map { UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: $0) }
        )
        return AccountPresentation(account: account, snapshot: snapshot, state: .current)
    }
    private func d(_ t: TimeInterval) -> Date { Date(timeIntervalSince1970: t) }
    private let now = Date(timeIntervalSince1970: 1000)

    func testEmptyReturnsNil() {
        XCTAssertNil(SoonestResetSummary.next(from: [], now: now))
    }
    func testAllNilOrPastReturnsNil() {
        let p = [pres("A", five: nil, weekly: d(500))] // weekly reset in the past
        XCTAssertNil(SoonestResetSummary.next(from: p, now: now))
    }
    func testPicksNearestFutureAcrossAccountsAndKinds() {
        let p = [
            pres("A", five: d(9000), weekly: d(5000)),
            pres("B", five: d(2000), weekly: d(8000)), // B 5h at 2000 is the soonest future
        ]
        let next = SoonestResetSummary.next(from: p, now: now)
        XCTAssertEqual(next, SoonestReset(accountLabel: "B", kind: .fiveHour, resetsAt: d(2000), label: nil))
    }
    func testIgnoresPastKeepsFuture() {
        let p = [pres("A", five: d(200), weekly: d(3000))] // 5h past, weekly future
        XCTAssertEqual(SoonestResetSummary.next(from: p, now: now)?.kind, .weekly)
    }

    /// A modelWeekly (Fable) reset that is sooner than every other window must
    /// be chosen, proving `.modelWeekly` is included in the candidate windows.
    /// It must also carry the API-provided label through to `SoonestReset`, so
    /// callers (MenuBarView) can render something more informative than a
    /// hardcoded "WK"/"5H" for a kind that has neither.
    func testSoonestResetConsidersModelWeekly() {
        let soon = Date(timeIntervalSince1970: 1_000)
        let snap = UsageSnapshot(accountID: UUID(), fetchedAt: Date(timeIntervalSince1970: 0),
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.5, resetsAt: Date(timeIntervalSince1970: 5_000)),
            weekly: nil,
            modelWeekly: UsageWindow(kind: .modelWeekly, remainingFraction: 0.5, resetsAt: soon, label: "Fable"))
        let pres = AccountPresentation(account: .init(id: snap.accountID, provider: .claude, label: "A",
            webProfileID: UUID(), displayOrder: 0, createdAt: Date(timeIntervalSince1970: 0)),
            snapshot: snap, state: .current)
        let best = SoonestResetSummary.next(from: [pres], now: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(best?.kind, .modelWeekly)
        XCTAssertEqual(best?.resetsAt, soon)
        XCTAssertEqual(best?.label, "Fable", "the API label must be carried through so the kind doesn't mislabel as WK/5H")
    }

    /// The `.fiveHour`/`.weekly` kinds have fixed "5H"/"WK" display text and
    /// carry no label from the API (the adapters never set one for those
    /// kinds); `.modelWeekly` has no fixed text and must fall back to its
    /// carried label instead.
    func testFiveHourAndWeeklyCarryNoLabel() {
        let p = [pres("A", five: d(2000), weekly: d(8000))]
        let best = SoonestResetSummary.next(from: p, now: now)
        XCTAssertEqual(best?.kind, .fiveHour)
        XCTAssertNil(best?.label, "5h/weekly windows carry no API label")
    }
}
