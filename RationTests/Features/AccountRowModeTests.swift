import XCTest
@testable import Ration

/// The Standard popover's row state (compact rows + folding): which rows
/// fold, which show sparklines and a chevron, and which gauge a folded row
/// keeps.
final class AccountRowModeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func mode(
        _ phase: InUsePhase,
        hasGauges: Bool = true,
        inUseDetection: Bool = true,
        folds: Bool = true,
        expanded: Bool = false
    ) -> AccountRowMode {
        AccountRowMode.make(
            phase: phase,
            hasGauges: hasGauges,
            inUseDetection: inUseDetection,
            foldsAccountsNotInUse: folds,
            userExpanded: expanded
        )
    }

    // MARK: Fold state

    func testRowNotInUseFoldsByDefault() {
        XCTAssertEqual(mode(.none), .folded)
    }

    /// The last-used tail is not "in use": its row folds like any other.
    func testLastUsedRowFolds() {
        XCTAssertEqual(mode(.lastUsed(age: 4000)), .folded)
    }

    func testInUseRowIsAlwaysExpandedWithSparklinesAndNoChevron() {
        for expanded in [false, true] {
            let row = mode(.inUse(age: 30), expanded: expanded)
            XCTAssertEqual(row, .expanded(sparklines: true, collapsible: false), "expanded: \(expanded)")
            XCTAssertFalse(row.showsChevron)
        }
    }

    func testRowTheUserExpandedShowsEverythingAndCanFoldAgain() {
        let row = mode(.none, expanded: true)
        XCTAssertEqual(row, .expanded(sparklines: true, collapsible: true))
        XCTAssertTrue(row.showsChevron)
        XCTAssertTrue(row.showsSparklines)
    }

    /// In-use detection off: nothing is in use, so nothing folds — every
    /// row shows expanded, and none offers a chevron.
    func testInUseDetectionOffExpandsEveryRow() {
        for phase in [InUsePhase.none, .lastUsed(age: 4000), .inUse(age: 30)] {
            for expanded in [false, true] {
                let row = mode(phase, inUseDetection: false, expanded: expanded)
                XCTAssertEqual(row, .expanded(sparklines: true, collapsible: false), "\(phase) expanded: \(expanded)")
            }
        }
    }

    /// The Settings switch off: compact rows, sparklines only while in use,
    /// no chevron anywhere.
    func testFoldSwitchOffShowsCompactRowsWithoutChevron() {
        XCTAssertEqual(mode(.none, folds: false), .expanded(sparklines: false, collapsible: false))
        XCTAssertEqual(mode(.none, folds: false, expanded: true), .expanded(sparklines: false, collapsible: false))
        XCTAssertEqual(mode(.inUse(age: 30), folds: false), .expanded(sparklines: true, collapsible: false))
    }

    /// Cursor spend and TypeSafe balance have no gauges to fold to.
    func testRowsWithoutGaugesNeverFold() {
        let row = mode(.none, hasGauges: false)
        XCTAssertFalse(row.isFolded)
        XCTAssertFalse(row.showsChevron)
    }

    func testOnlyFoldedRowsAreFolded() {
        XCTAssertTrue(AccountRowMode.folded.isFolded)
        XCTAssertFalse(AccountRowMode.expanded(sparklines: true, collapsible: true).isFolded)
        XCTAssertFalse(AccountRowMode.folded.showsSparklines)
    }

    /// The chevron (or a click on the row) asks for the other state; a row
    /// without a chevron asks for nothing.
    func testToggleTarget() {
        XCTAssertEqual(AccountRowMode.folded.toggledExpansion, true)
        XCTAssertEqual(AccountRowMode.expanded(sparklines: true, collapsible: true).toggledExpansion, false)
        XCTAssertNil(AccountRowMode.expanded(sparklines: true, collapsible: false).toggledExpansion)
        XCTAssertNil(AccountRowMode.expanded(sparklines: false, collapsible: false).toggledExpansion)
    }

    func testHasGaugesFollowsTheLimitLayout() {
        XCTAssertTrue(AccountRowMode.hasGauges(.claude))
        XCTAssertTrue(AccountRowMode.hasGauges(.chatGPT))
        XCTAssertFalse(AccountRowMode.hasGauges(.cursor))
        XCTAssertFalse(AccountRowMode.hasGauges(.typeSafe))
    }

    // MARK: Tightest gauge

    private func window(_ kind: UsageWindowKind, used: Double, resetsIn: TimeInterval?) -> UsageWindow {
        UsageWindow(
            kind: kind, remainingFraction: 1 - used,
            resetsAt: resetsIn.map { now.addingTimeInterval($0) },
            label: kind == .modelWeekly ? "Fable" : nil
        )
    }

    private func snapshot(fiveHour: UsageWindow? = nil, weekly: UsageWindow? = nil, fable: UsageWindow? = nil) -> UsageSnapshot {
        UsageSnapshot(accountID: UUID(), fetchedAt: now, fiveHour: fiveHour, weekly: weekly, modelWeekly: fable)
    }

    private let claudeKinds: [UsageWindowKind] = [.modelWeekly, .fiveHour, .weekly]

    func testTightestIsTheHighestPercent() {
        let snap = snapshot(
            fiveHour: window(.fiveHour, used: 0.0, resetsIn: 3600),
            weekly: window(.weekly, used: 0.48, resetsIn: 3 * 86_400),
            fable: window(.modelWeekly, used: 0.35, resetsIn: 3 * 86_400)
        )
        XCTAssertEqual(AccountRowMode.tightestKind(kinds: claudeKinds, snapshot: snap), .weekly)
    }

    /// Ties go to the limit that resets soonest.
    func testTiesGoToTheSoonestReset() {
        let snap = snapshot(
            fiveHour: window(.fiveHour, used: 0.5, resetsIn: 2 * 3600),
            weekly: window(.weekly, used: 0.5, resetsIn: 3 * 86_400),
            fable: window(.modelWeekly, used: 0.5, resetsIn: 86_400)
        )
        XCTAssertEqual(AccountRowMode.tightestKind(kinds: claudeKinds, snapshot: snap), .fiveHour)
    }

    /// The tie is on the percent the row DRAWS: 48.4 % and 47.6 % both read
    /// "48%", so the sooner reset wins rather than an invisible decimal.
    func testTiesAreJudgedOnTheDrawnPercent() {
        let snap = snapshot(
            fiveHour: window(.fiveHour, used: 0.476, resetsIn: 3600),
            weekly: window(.weekly, used: 0.484, resetsIn: 3 * 86_400)
        )
        XCTAssertEqual(AccountRowMode.tightestKind(kinds: [.fiveHour, .weekly], snapshot: snap), .fiveHour)
    }

    /// A known reset beats an unscheduled one; a full tie keeps column order.
    func testUnscheduledResetLosesTheTieAndAFullTieKeepsColumnOrder() {
        let unscheduled = snapshot(
            fiveHour: window(.fiveHour, used: 1.0, resetsIn: nil),
            weekly: window(.weekly, used: 1.0, resetsIn: 5 * 86_400)
        )
        XCTAssertEqual(AccountRowMode.tightestKind(kinds: [.fiveHour, .weekly], snapshot: unscheduled), .weekly)

        let same = snapshot(
            fiveHour: window(.fiveHour, used: 0.2, resetsIn: 3600),
            weekly: window(.weekly, used: 0.2, resetsIn: 3600)
        )
        XCTAssertEqual(AccountRowMode.tightestKind(kinds: [.fiveHour, .weekly], snapshot: same), .fiveHour)
    }

    /// A limit with no reading never wins over one with a reading; with no
    /// readings at all the row keeps its first column (drawn as "—").
    func testMissingWindowsAreSkipped() {
        let partial = snapshot(weekly: window(.weekly, used: 0.1, resetsIn: 3600))
        XCTAssertEqual(AccountRowMode.tightestKind(kinds: [.fiveHour, .weekly], snapshot: partial), .weekly)
        XCTAssertEqual(AccountRowMode.tightestKind(kinds: claudeKinds, snapshot: nil), .modelWeekly)
        XCTAssertNil(AccountRowMode.tightestKind(kinds: [], snapshot: partial))
    }
}
