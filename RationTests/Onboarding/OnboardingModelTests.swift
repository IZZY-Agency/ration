import XCTest
@testable import Ration

@MainActor
final class OnboardingModelTests: XCTestCase {
    private func model(accountCountAtOpen: Int = 0) -> OnboardingModel {
        OnboardingModel(accountCountAtOpen: accountCountAtOpen)
    }

    func testStartsOnWelcome() {
        XCTAssertEqual(model().step, .welcome)
    }

    func testAdvanceAndGoBackWalkTheSequence() {
        let sut = model()
        sut.advance()
        XCTAssertEqual(sut.step, .connect)
        sut.goBack()
        XCTAssertEqual(sut.step, .welcome)
    }

    func testGoBackFromFirstStepIsANoOp() {
        let sut = model()
        sut.goBack()
        XCTAssertEqual(sut.step, .welcome)
        XCTAssertFalse(sut.canGoBack)
    }

    func testAdvanceFromFinalStepIsANoOp() {
        let sut = model()
        sut.advance()
        sut.advance()
        sut.advance()
        XCTAssertEqual(sut.step, .done)
        XCTAssertTrue(sut.isFinalStep)
        sut.advance()
        XCTAssertEqual(sut.step, .done)
    }

    func testPositionCountsEveryStep() {
        let sut = model()
        XCTAssertEqual(sut.position.index, 1)
        XCTAssertEqual(sut.position.total, 4)
    }

    func testAccountAddedOnConnectStepAdvances() {
        let sut = model(accountCountAtOpen: 0)
        sut.advance()
        XCTAssertEqual(sut.step, .connect)

        sut.signInStateDidChange(accountCount: 1, sessionsInFlight: 0)

        XCTAssertEqual(sut.step, .launchAtLogin)
    }

    func testRepublishedUnchangedCountDoesNotAdvance() {
        // Re-opening the guide with accounts already connected must not skip
        // the connect step just because `presentations` republishes.
        let sut = model(accountCountAtOpen: 3)
        sut.advance()

        sut.signInStateDidChange(accountCount: 3, sessionsInFlight: 0)

        XCTAssertEqual(sut.step, .connect)
    }

    func testCountBelowBaselineDoesNotAdvance() {
        let sut = model(accountCountAtOpen: 3)
        sut.advance()

        sut.signInStateDidChange(accountCount: 2, sessionsInFlight: 0)

        XCTAssertEqual(sut.step, .connect)
    }

    func testSecondAccountDoesNotAdvanceASecondTime() {
        let sut = model(accountCountAtOpen: 0)
        sut.advance()
        sut.signInStateDidChange(accountCount: 1, sessionsInFlight: 0)
        XCTAssertEqual(sut.step, .launchAtLogin)

        sut.signInStateDidChange(accountCount: 2, sessionsInFlight: 0)

        XCTAssertEqual(sut.step, .launchAtLogin)
    }

    func testMidTransactionAccountCountDoesNotAdvance() {
        // `completeSignIn` calls `accountStore.add` — which publishes at once —
        // and only then saves the snapshot, rolling the account back out if
        // that save fails. So a FAILED sign-in really does publish 0 → 1 → 0.
        // Advancing on the transient would move the wizard past a sign-in that
        // never happened, and latch so the retry could never advance it.
        let sut = model(accountCountAtOpen: 0)
        sut.advance()

        sut.signInStateDidChange(accountCount: 1, sessionsInFlight: 1)

        XCTAssertEqual(
            sut.step,
            .connect,
            "an account published while its session is still committing is not a completed sign-in"
        )
    }

    func testRolledBackSignInStillAdvancesOnASuccessfulRetry() {
        let sut = model(accountCountAtOpen: 0)
        sut.advance()
        // Failed attempt: transient add, then rollback.
        sut.signInStateDidChange(accountCount: 1, sessionsInFlight: 1)
        sut.signInStateDidChange(accountCount: 0, sessionsInFlight: 1)
        XCTAssertEqual(sut.step, .connect)

        // Retry commits and the session closes.
        sut.signInStateDidChange(accountCount: 1, sessionsInFlight: 0)

        XCTAssertEqual(sut.step, .launchAtLogin)
    }

    func testAdvanceDefersWhileAnUnrelatedSignInIsStillOpen() {
        let sut = model(accountCountAtOpen: 0)
        sut.advance()

        sut.signInStateDidChange(accountCount: 1, sessionsInFlight: 1)
        XCTAssertEqual(sut.step, .connect)

        // That other session closes; the committed account is still there.
        sut.signInStateDidChange(accountCount: 1, sessionsInFlight: 0)

        XCTAssertEqual(sut.step, .launchAtLogin)
    }

    func testSignInCompletedWhileOnAnotherStepAdvancesOnReturnToConnect() {
        // Open sign-in from Connect, press Back, finish signing in, then
        // Continue. The progress transition is consumed while on Welcome, so
        // without re-evaluating on step change the user is stranded on Connect.
        let sut = model(accountCountAtOpen: 0)
        sut.advance()
        XCTAssertEqual(sut.step, .connect)
        sut.goBack()
        XCTAssertEqual(sut.step, .welcome)

        sut.signInStateDidChange(accountCount: 1, sessionsInFlight: 0)
        XCTAssertEqual(sut.step, .welcome, "no jump from an unrelated step")

        sut.advance()

        XCTAssertEqual(
            sut.step,
            .launchAtLogin,
            "arriving at Connect with a completed sign-in must not strand the user"
        )
    }

    func testBackFromLaunchAtLoginStaysOnConnect() {
        // The other half of the same rule: once auto-advance HAS fired, Back
        // must stick rather than bouncing the user forward again.
        let sut = model(accountCountAtOpen: 0)
        sut.advance()
        sut.signInStateDidChange(accountCount: 1, sessionsInFlight: 0)
        XCTAssertEqual(sut.step, .launchAtLogin)

        sut.goBack()

        XCTAssertEqual(sut.step, .connect)
    }

    func testAccountAddedWhileNotOnConnectStepDoesNotAdvance() {
        let sut = model(accountCountAtOpen: 0)

        sut.signInStateDidChange(accountCount: 1, sessionsInFlight: 0)

        XCTAssertEqual(sut.step, .welcome)
    }

    func testBeginSignInOpensTheReturnedSession() {
        let sut = model()
        sut.advance()
        let sessionID = UUID()
        var opened: UUID?

        sut.beginSignIn(
            provider: .claude,
            using: { _ in sessionID },
            open: { opened = $0 }
        )

        XCTAssertEqual(opened, sessionID)
        XCTAssertNil(sut.signInError)
        XCTAssertEqual(sut.step, .connect)
    }

    func testBeginSignInFailureSurfacesErrorAndStaysOnConnect() {
        let sut = model()
        sut.advance()
        var opened: UUID?

        sut.beginSignIn(
            provider: .claude,
            using: { _ in throw AccountStoreError.operationInProgress },
            open: { opened = $0 }
        )

        XCTAssertNil(opened)
        XCTAssertNotNil(sut.signInError)
        XCTAssertEqual(sut.step, .connect)
    }

    func testBeginSignInClearsAPreviousError() {
        let sut = model()
        sut.advance()
        sut.beginSignIn(
            provider: .claude,
            using: { _ in throw AccountStoreError.operationInProgress },
            open: { _ in }
        )
        XCTAssertNotNil(sut.signInError)

        sut.beginSignIn(provider: .cursor, using: { _ in UUID() }, open: { _ in })

        XCTAssertNil(sut.signInError)
    }
}
