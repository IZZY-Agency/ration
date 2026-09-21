import XCTest
@testable import Ration

final class CursorSpendTests: XCTestCase {
    func testLegacySnapshotDecodesWithoutCursorSpend() throws {
        let legacy = """
        {"accountID":"\(UUID().uuidString)","fetchedAt":0}
        """
        let snap = try JSONDecoder().decode(UsageSnapshot.self, from: Data(legacy.utf8))
        XCTAssertNil(snap.cursorSpend)
    }

    /// A `snapshots.json` written by 0.28.1 carries a `cursorSpend` WITHOUT
    /// `periodStart`. It must still decode — with `periodStart == nil`, never a
    /// fabricated boundary and never a throw that would drop the whole store.
    func testSnapshotWrittenBeforePeriodStartDecodesWithNilPeriodStart() throws {
        let legacy = """
        {"accountID":"\(UUID().uuidString)","fetchedAt":0,
         "cursorSpend":{"planLabel":"Pro","resetsAt":5000,"spentCents":42}}
        """
        let snap = try JSONDecoder().decode(UsageSnapshot.self, from: Data(legacy.utf8))
        let spend = try XCTUnwrap(snap.cursorSpend)
        XCTAssertNil(spend.periodStart)
        XCTAssertEqual(spend.spentCents, 42)
        XCTAssertEqual(spend.resetsAt, Date(timeIntervalSinceReferenceDate: 5000))
    }

    /// One rule for "is there a countdown to show", shared by the card and the
    /// drop row so the two surfaces cannot disagree.
    func testFutureResetIsOnlyAnEndStillAhead() {
        let now = Date(timeIntervalSince1970: 1_000)
        let ahead = CursorSpend(spentCents: 0, periodStart: nil, resetsAt: now.addingTimeInterval(1), planLabel: "Pro")
        XCTAssertEqual(ahead.futureReset(relativeTo: now), now.addingTimeInterval(1))
        let atNow = CursorSpend(spentCents: 0, periodStart: nil, resetsAt: now, planLabel: "Pro")
        XCTAssertNil(atNow.futureReset(relativeTo: now))
        let behind = CursorSpend(spentCents: 0, periodStart: nil, resetsAt: now.addingTimeInterval(-1), planLabel: "Pro")
        XCTAssertNil(behind.futureReset(relativeTo: now))
    }

    func testCursorSpendRoundTripsAndComputesDollars() throws {
        let spend = CursorSpend(spentCents: 1234, periodStart: Date(timeIntervalSince1970: 1000), resetsAt: Date(timeIntervalSince1970: 5000), planLabel: "Pro")
        XCTAssertEqual(spend.spentDollars, 12.34, accuracy: 1e-9)
        let snap = UsageSnapshot(accountID: UUID(), fetchedAt: .init(timeIntervalSince1970: 1),
                                 fiveHour: nil, weekly: nil, cursorSpend: spend)
        let decoded = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snap))
        XCTAssertEqual(decoded.cursorSpend, spend)
    }
}
