import XCTest
@testable import Ration

final class AccountLimitLayoutTests: XCTestCase {
    private func snap(model: UsageWindow?) -> UsageSnapshot {
        UsageSnapshot(accountID: UUID(), fetchedAt: Date(timeIntervalSince1970: 0),
                      fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.9, resetsAt: nil),
                      weekly: UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: nil),
                      modelWeekly: model)
    }
    func testClaudeShowsModelWeeklyOnlyWhenPresent() {
        let withModel = snap(model: UsageWindow(kind: .modelWeekly, remainingFraction: 0.54, resetsAt: nil, label: "Fable"))
        XCTAssertEqual(AccountLimitLayout.kinds(for: .claude, snapshot: withModel), [.modelWeekly, .fiveHour, .weekly])
        let without = snap(model: nil)
        XCTAssertEqual(AccountLimitLayout.kinds(for: .claude, snapshot: without), [.fiveHour, .weekly]) // Max-only
    }
    func testClaudeNilSnapshotShowsBaseWindows() {
        XCTAssertEqual(AccountLimitLayout.kinds(for: .claude, snapshot: nil), [.fiveHour, .weekly])
    }
    /// A verified Claude Ultra account (since 2026-10-30) reports no 5-hour
    /// window: its row shows only the limits it has, no empty 5h column.
    func testClaudeWithoutAFiveHourWindowShowsOnlyItsLimits() {
        let fable = UsageWindow(kind: .modelWeekly, remainingFraction: 0.9, resetsAt: nil, label: "Fable")
        let weekly = UsageWindow(kind: .weekly, remainingFraction: 0.7, resetsAt: nil)
        let ultra = UsageSnapshot(accountID: UUID(), fetchedAt: Date(timeIntervalSince1970: 0),
                                  fiveHour: nil, weekly: weekly, modelWeekly: fable)
        XCTAssertEqual(AccountLimitLayout.kinds(for: .claude, snapshot: ultra), [.modelWeekly, .weekly])
        let ultraNoFable = UsageSnapshot(accountID: UUID(), fetchedAt: Date(timeIntervalSince1970: 0),
                                         fiveHour: nil, weekly: weekly)
        XCTAssertEqual(AccountLimitLayout.kinds(for: .claude, snapshot: ultraNoFable), [.weekly])
    }

    /// Max and Pro keep their 5-hour column wherever it is reported.
    func testClaudeKeepsTheFiveHourColumnWhereReported() {
        XCTAssertEqual(AccountLimitLayout.kinds(for: .claude, snapshot: snap(model: nil)), [.fiveHour, .weekly])
    }

    func testChatGPTNeverShowsModelWeekly() {
        let s = snap(model: UsageWindow(kind: .modelWeekly, remainingFraction: 0.5, resetsAt: nil, label: "Fable"))
        XCTAssertFalse(AccountLimitLayout.kinds(for: .chatGPT, snapshot: s).contains(.modelWeekly))
    }
    func testTitleUsesApiLabelForModelWeekly() {
        let s = snap(model: UsageWindow(kind: .modelWeekly, remainingFraction: 0.5, resetsAt: nil, label: "Fable"))
        XCTAssertEqual(AccountLimitLayout.title(for: .modelWeekly, snapshot: s), "Fable")
        XCTAssertEqual(AccountLimitLayout.title(for: .fiveHour, snapshot: s), "5h")
        XCTAssertEqual(AccountLimitLayout.title(for: .weekly, snapshot: s), "wk")
    }
}
