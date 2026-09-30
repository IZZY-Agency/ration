import XCTest
@testable import Ration

/// The one line under the Claude section header (spec §4.6: the popover
/// shows what happened whatever the notification settings).
final class ClaudeCodeStatusLineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_100_000)
    private func label(_ uuid: String) -> String { uuid == "acc-B" ? "Personal" : "Work" }

    private func line(_ status: ClaudeCodeStatus?, paused: Bool = false, prompt: String? = nil) -> ClaudeCodeStatusLine? {
        var state = ClaudeCodeState()
        state.status = status
        state.autoSwitchPaused = paused
        return ClaudeCodeStatusLine.make(state: state, rememberPrompt: prompt, label: label, now: now)
    }

    func testNothingToSay() {
        XCTAssertNil(line(nil))
    }

    /// The spec shows "waiting for fresh usage".
    func testWaitingIsShown() {
        XCTAssertEqual(line(.waiting(at: now)), .waiting)
    }

    func testARecentSwitchIsShownForAnHour() {
        XCTAssertEqual(line(.switched(at: now.addingTimeInterval(-600), from: "acc-A", to: "acc-B", automatic: true)),
                       .switched(to: "Personal", automatic: true))
        XCTAssertNil(line(.switched(at: now.addingTimeInterval(-3_601), from: "acc-A", to: "acc-B", automatic: true)))
    }

    func testProblemsOutrankEverythingElse() {
        XCTAssertEqual(line(.needsAttention(at: now), paused: true, prompt: "X"), .needsAttention)
        XCTAssertEqual(line(.conflict(at: now), paused: true, prompt: "X"), .paused)
        XCTAssertEqual(line(.failed(at: now), prompt: "X"), .failed)
        XCTAssertEqual(line(.conflict(at: now)), .failed)
        XCTAssertEqual(line(.noRoom(at: now), prompt: "X"), .noRoom)
    }

    func testAFailureIsShownForADay() {
        XCTAssertNil(line(.failed(at: now.addingTimeInterval(-86_401))))
    }

    func testTheRememberPromptOutranksAnOldSwitch() {
        XCTAssertEqual(line(.switched(at: now, from: "acc-A", to: "acc-B", automatic: false), prompt: "ai@example.com's Organization"),
                       .rememberPrompt(organization: "ai@example.com's Organization"))
    }
}
