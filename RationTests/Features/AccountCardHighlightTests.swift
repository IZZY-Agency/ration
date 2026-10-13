import SwiftUI
import XCTest
@testable import Ration

@MainActor
final class AccountCardHighlightTests: XCTestCase {
    /// Rows are borderless: the in-use row's signal is the activity green's
    /// wash (and the green IN USE mark). Without the frame that once dimmed
    /// for the last-used tail, a washed last-used row would read as in use —
    /// and it folds like an idle row — so only the bright phase is washed.
    func testWashedOnlyWhileInUse() {
        XCTAssertTrue(AccountCardView.isHighlighted(phase: .inUse(age: 10)))
        XCTAssertFalse(AccountCardView.isHighlighted(phase: .lastUsed(age: 4000)))
        XCTAssertFalse(AccountCardView.isHighlighted(phase: .none))
    }

    /// The section header names Claude, ChatGPT and Cursor; only a TypeSafe
    /// account, under "API", keeps its provider chip.
    func testOnlyAPIAccountsKeepTheProviderChip() {
        XCTAssertFalse(AccountCardView.showsProviderChip(.claude))
        XCTAssertFalse(AccountCardView.showsProviderChip(.chatGPT))
        XCTAssertFalse(AccountCardView.showsProviderChip(.cursor))
        XCTAssertTrue(AccountCardView.showsProviderChip(.typeSafe))
    }

    func testInsetConstantsDocumentTheOriginalThirteenPointSplit() {
        // Content must not shift: the inset moves from the list to the card.
        // This only documents the two constants sum to the original 13pt —
        // SwiftUI geometry isn't unit-testable here (no view tests, no
        // introspection library), so it cannot verify either constant is
        // actually consumed by `MenuBarView.accountList` / `AccountCardView`.
        // That consumption is verified by inspection, not by this assertion.
        XCTAssertEqual(AccountListMetrics.listInset + AccountListMetrics.cardInset, 13)
    }
}
