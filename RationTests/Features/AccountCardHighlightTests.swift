import XCTest
@testable import Ration

@MainActor
final class AccountCardHighlightTests: XCTestCase {
    func testHighlightedForBothActivePhases() {
        XCTAssertTrue(AccountCardView.isHighlighted(phase: .inUse(age: 10)))
        XCTAssertTrue(AccountCardView.isHighlighted(phase: .lastUsed(age: 4000)))
    }

    func testNotHighlightedWhenIdle() {
        XCTAssertFalse(AccountCardView.isHighlighted(phase: .none))
    }

    /// The activity signal is ONE color everywhere — `Theme.active`, the same
    /// green as the menu-bar dot and the IN USE pill — never the provider
    /// accent (identity and state are separate channels). Full green while in
    /// use; the last-used tail dims the same hue so green intensity encodes
    /// recency, not a different pattern.
    func testHighlightStrokeIsActiveGreenByPhase() {
        XCTAssertEqual(
            AccountCardView.highlightStroke(phase: .inUse(age: 10)),
            Theme.active
        )
        XCTAssertEqual(
            AccountCardView.highlightStroke(phase: .lastUsed(age: 4000)),
            Theme.active.opacity(0.35)
        )
        XCTAssertEqual(AccountCardView.highlightStroke(phase: .none), .clear)
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
