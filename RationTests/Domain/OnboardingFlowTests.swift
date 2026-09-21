import XCTest
@testable import Ration

final class OnboardingFlowTests: XCTestCase {
    func testStepsAreTheCanonicalSequence() {
        XCTAssertEqual(
            OnboardingFlow.steps,
            [.welcome, .connect, .launchAtLogin, .done]
        )
    }

    func testNextTraversesTheFullSequence() {
        XCTAssertEqual(OnboardingFlow.next(after: .welcome), .connect)
        XCTAssertEqual(OnboardingFlow.next(after: .connect), .launchAtLogin)
        XCTAssertEqual(OnboardingFlow.next(after: .launchAtLogin), .done)
        XCTAssertNil(OnboardingFlow.next(after: .done))
    }

    func testPreviousTraversesBackwardsAndStopsAtFirstStep() {
        XCTAssertEqual(OnboardingFlow.previous(before: .done), .launchAtLogin)
        XCTAssertEqual(OnboardingFlow.previous(before: .launchAtLogin), .connect)
        XCTAssertEqual(OnboardingFlow.previous(before: .connect), .welcome)
        XCTAssertNil(OnboardingFlow.previous(before: .welcome))
    }

    func testPositionIsOneBasedAndTotalIsTheSequenceLength() {
        let first = OnboardingFlow.position(of: .welcome)
        XCTAssertEqual(first.index, 1)
        XCTAssertEqual(first.total, 4)

        let last = OnboardingFlow.position(of: .done)
        XCTAssertEqual(last.index, 4)
        XCTAssertEqual(last.total, 4)
    }

    func testPresentsOnlyForFreshInstallWithCleanSettings() {
        XCTAssertTrue(
            OnboardingFlow.shouldPresentAtLaunch(
                hasCompletedOnboarding: false,
                accountCount: 0,
                settingsLoadFailed: false
            )
        )
    }

    func testDoesNotPresentOnceCompleted() {
        XCTAssertFalse(
            OnboardingFlow.shouldPresentAtLaunch(
                hasCompletedOnboarding: true,
                accountCount: 0,
                settingsLoadFailed: false
            )
        )
    }

    func testDoesNotPresentForAnExistingInstallThatHasAccounts() {
        // The upgrade case: the flag is absent from an existing settings.json
        // and decodes to false, so account count is what keeps the wizard away.
        XCTAssertFalse(
            OnboardingFlow.shouldPresentAtLaunch(
                hasCompletedOnboarding: false,
                accountCount: 1,
                settingsLoadFailed: false
            )
        )
    }

    func testFailsClosedWhenSettingsFailedToLoad() {
        // `false` from substituted defaults is not a user choice.
        XCTAssertFalse(
            OnboardingFlow.shouldPresentAtLaunch(
                hasCompletedOnboarding: false,
                accountCount: 0,
                settingsLoadFailed: true
            )
        )
    }
}
