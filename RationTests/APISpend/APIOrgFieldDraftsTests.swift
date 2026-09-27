import XCTest
@testable import Ration

/// The fields used to save on Return only, so a budget typed before clicking
/// away was lost. They now save when they lose focus or the pane closes, but
/// never per keystroke ("1" on the way to "100" would set a $1 budget).
@MainActor
final class APIOrgFieldDraftsTests: XCTestCase {
    private let en = Locale(identifier: "en_US")

    private func drafts(budget: Int? = 60_000, renamed: @escaping (String) -> Void = { _ in },
                        budgeted: @escaping (Int?) -> Void = { _ in }) -> APIOrgFieldDrafts {
        APIOrgFieldDrafts(label: "Work API", budgetCents: budget, locale: en, onRename: renamed, onBudget: budgeted)
    }

    func testFieldsStartFromTheSavedValues() {
        let d = drafts()
        XCTAssertEqual(d.label, "Work API")
        XCTAssertEqual(d.budget, "600")
    }

    func testTypingAloneSavesNothingLeavingTheFieldSavesOnce() {
        var saved: [Int?] = []
        let d = drafts(budgeted: { saved.append($0) })
        d.budget = "1"; d.budget = "10"; d.budget = "100"
        XCTAssertTrue(saved.isEmpty, "never per keystroke")
        d.commitBudget()
        d.commitBudget()
        XCTAssertEqual(saved, [10_000], "once, and not again for the same value")
    }

    func testUnreadableOrUnchangedBudgetsSaveNothing() {
        var saved: [Int?] = []
        let d = drafts(budgeted: { saved.append($0) })
        d.budget = "12,34"; d.commitBudget()
        d.budget = "600"; d.commitBudget()
        XCTAssertTrue(saved.isEmpty)
    }

    func testClearingTheFieldRemovesTheBudget() {
        var saved: [Int?] = []
        let d = drafts(budgeted: { saved.append($0) })
        d.budget = "  "; d.commitBudget()
        XCTAssertEqual(saved, [nil])
    }

    func testRenameSavesOnlyARealChange() {
        var saved: [String] = []
        let d = drafts(renamed: { saved.append($0) })
        d.label = "Work API"; d.commitLabel()
        d.label = "  "; d.commitLabel()
        d.label = "Work"; d.commitLabel(); d.commitLabel()
        XCTAssertEqual(saved, ["Work"])
    }

    func testClosingThePaneSavesBoth() {
        var renamed: [String] = [], budgeted: [Int?] = []
        let d = drafts(renamed: { renamed.append($0) }, budgeted: { budgeted.append($0) })
        d.label = "Work"; d.budget = "700"
        d.commitAll()
        XCTAssertEqual(renamed, ["Work"])
        XCTAssertEqual(budgeted, [70_000])
    }
}
