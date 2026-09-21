import XCTest
@testable import Ration

@MainActor
final class AccountDetailPausedTests: XCTestCase {
    func testPausedStateDrivesControls() {
        let paused = AccountDetailPauseState(isPaused: true)
        XCTAssertEqual(paused.buttonTitle, "Resume account")
        XCTAssertTrue(paused.disablesAutomationAndBilling)
        XCTAssertEqual(
            paused.explanation,
            "Paused: not refreshed, excluded from warm-up, hidden from the menu bar. Sign-in is kept."
        )

        let active = AccountDetailPauseState(isPaused: false)
        XCTAssertEqual(active.buttonTitle, "Pause account")
        XCTAssertFalse(active.disablesAutomationAndBilling)
        XCTAssertNil(active.explanation)
    }
}
