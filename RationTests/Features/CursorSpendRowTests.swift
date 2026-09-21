import XCTest
@testable import Ration

final class CursorSpendRowTests: XCTestCase {
    func testFormatsSpendAndReset() {
        let now = Date(timeIntervalSince1970: 0)
        let spend = CursorSpend(spentCents: 1234, periodStart: now.addingTimeInterval(-86_400 * 10), resetsAt: now.addingTimeInterval(5 * 86400), planLabel: "Pro")
        let out = CursorSpendRow.text(for: spend, now: now)
        XCTAssertEqual(out.headline, "$12.34")
        XCTAssertTrue(out.caption.contains("5d"))
        XCTAssertTrue(out.isAvailable)
    }

    /// Live-observed 2026-08-27: Cursor's `get-monthly-invoice` reports
    /// `periodEndMs` as the fetch time for the open invoice, so the reported
    /// "reset" is never in the future. The card must not claim a reset it
    /// does not have — "resets in now" is a lie dressed as a countdown.
    func testAResetThatIsNotInTheFutureIsNotClaimed() {
        let now = Date(timeIntervalSince1970: 1_000)
        let spend = CursorSpend(
            spentCents: 0,
            periodStart: Date(timeIntervalSince1970: 0),
            resetsAt: now.addingTimeInterval(-1),
            planLabel: "Pro"
        )
        let out = CursorSpendRow.text(for: spend, now: now)
        XCTAssertEqual(out.caption, "no usage-based charges")
        XCTAssertTrue(out.isAvailable)

        let spent = CursorSpend(
            spentCents: 1,
            periodStart: Date(timeIntervalSince1970: 0),
            resetsAt: now,
            planLabel: "Pro"
        )
        XCTAssertEqual(CursorSpendRow.text(for: spent, now: now).caption, "this cycle")
    }

    func testNilSpendIsUnavailable() {
        XCTAssertFalse(CursorSpendRow.text(for: nil, now: Date()).isAvailable)
    }

    func testZeroSpendIsAvailable() {
        // Free plan / no usage-based spend this cycle is a real, valid state —
        // it must render "$0.00", never fall back to the unavailable "—".
        let now = Date(timeIntervalSince1970: 0)
        let spend = CursorSpend(spentCents: 0, periodStart: now.addingTimeInterval(-86_400 * 10), resetsAt: now.addingTimeInterval(86400), planLabel: "Free")
        let out = CursorSpendRow.text(for: spend, now: now)
        XCTAssertEqual(out.headline, "$0.00")
        XCTAssertTrue(out.isAvailable)
    }

    func testZeroSpendCaptionNamesTheEmptyStateExplicitly() {
        // Live-verified 2026-07-28: an account inside its included allowance has
        // NO usage-based events at all, so $0.00 is the steady state. The caption
        // must distinguish that true zero from a failed read.
        let now = Date(timeIntervalSince1970: 0)
        let spend = CursorSpend(
            spentCents: 0,
            periodStart: now.addingTimeInterval(-86_400 * 10),
            resetsAt: now.addingTimeInterval(4 * 86400),
            planLabel: "Pro"
        )
        let out = CursorSpendRow.text(for: spend, now: now)
        XCTAssertTrue(out.caption.contains("no usage-based charges"))
        XCTAssertFalse(out.caption.contains("this cycle"))
        XCTAssertTrue(out.caption.contains("4d"))
    }

    func testNonZeroSpendCaptionUsesTheCycleWording() {
        let now = Date(timeIntervalSince1970: 0)
        let spend = CursorSpend(
            spentCents: 1,
            periodStart: now.addingTimeInterval(-86_400 * 10),
            resetsAt: now.addingTimeInterval(4 * 86400),
            planLabel: "Pro"
        )
        let out = CursorSpendRow.text(for: spend, now: now)
        XCTAssertTrue(out.caption.contains("this cycle"))
        XCTAssertFalse(out.caption.contains("no usage-based charges"))
    }
}
