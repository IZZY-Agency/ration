import XCTest
@testable import Ration

/// The one Codex line in the popover (spec §4.6, §5: what happened, whatever
/// the notification settings), one test per precedence step.
final class CodexStatusLineTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_100_000)
    private func label(_ login: String) -> String { login == "acct-B|user-2" ? "Personal" : "Work" }

    private func line(_ status: CodexStatus?, paused: Bool = false, prompt: String? = nil) -> CodexStatusLine? {
        var state = CodexState()
        state.status = status
        state.autoSwitchPaused = paused
        return CodexStatusLine.make(state: state, rememberPrompt: prompt, label: label, now: now)
    }

    func testNothingToSay() {
        XCTAssertNil(line(nil))
    }

    func testNeedsAttentionOutranksEverything() {
        XCTAssertEqual(line(.needsAttention(at: now.addingTimeInterval(-10 * 86_400)), paused: true, prompt: "x@example.com"), .needsAttention)
    }

    /// A mixed file pauses automatic switching too; the cause is what the user must see.
    func testADamagedFileOutranksThePause() {
        XCTAssertEqual(line(.damaged(at: now.addingTimeInterval(-10 * 86_400)), paused: true, prompt: "x@example.com"), .damaged)
    }

    /// A stale copy pauses automatic switching too; within its
    /// day, "sign in again" is what the user must see, not the pause.
    func testAStaleLoginOutranksThePause() {
        XCTAssertEqual(line(.stale(at: now.addingTimeInterval(-600), login: "acct-B|user-2"), paused: true),
                       .stale(account: "Personal"))
        XCTAssertEqual(line(.stale(at: now.addingTimeInterval(-86_401), login: "acct-B|user-2"), paused: true), .paused)
    }

    func testThePauseOutranksAFailure() {
        XCTAssertEqual(line(.conflict(at: now), paused: true, prompt: "x@example.com"), .paused)
        XCTAssertEqual(line(nil, paused: true), .paused)
    }

    func testAFailureOrConflictIsShownForADay() {
        XCTAssertEqual(line(.failed(at: now), prompt: "x@example.com"), .failed)
        XCTAssertEqual(line(.conflict(at: now.addingTimeInterval(-86_400))), .failed)
        XCTAssertNil(line(.failed(at: now.addingTimeInterval(-86_401))))
    }

    /// "Sign in to <account> in Codex, then Remember again".
    func testAStaleLoginIsShownForADayWithItsLabel() {
        XCTAssertEqual(line(.stale(at: now.addingTimeInterval(-600), login: "acct-B|user-2"), prompt: "x@example.com"),
                       .stale(account: "Personal"))
        XCTAssertNil(line(.stale(at: now.addingTimeInterval(-86_401), login: "acct-B|user-2")))
    }

    func testNoRoomAndWaitingOutrankThePrompt() {
        XCTAssertEqual(line(.noRoom(at: now.addingTimeInterval(-3 * 86_400)), prompt: "x@example.com"), .noRoom)
        XCTAssertEqual(line(.waiting(at: now.addingTimeInterval(-3 * 86_400)), prompt: "x@example.com"), .waiting)
    }

    func testTheRememberPromptOutranksARecentSwitch() {
        XCTAssertEqual(line(.switched(at: now, from: "acct-A|user-1", to: "acct-B|user-2", automatic: false), prompt: "x@example.com"),
                       .rememberPrompt(email: "x@example.com"))
    }

    /// Codex refreshed the target while Ration switched — a switch,
    /// but not with Ration's bytes; the line says so.
    func testAnUnverifiedSwitchKeepsItsMark() {
        XCTAssertEqual(line(.switched(at: now, from: "acct-A|user-1", to: "acct-B|user-2", automatic: true, verified: false)),
                       .switched(to: "Personal", automatic: true, verified: false))
        XCTAssertEqual(line(.switched(at: now, from: "acct-A|user-1", to: "acct-B|user-2", automatic: false)),
                       .switched(to: "Personal", automatic: false, verified: true))
    }

    /// A switch to another seat of the workspace keeps its mark —
    /// running sessions may follow it — whether or not it was verified.
    func testASameWorkspaceSwitchKeepsItsMark() {
        XCTAssertEqual(line(.switched(at: now, from: "acct-X|user-1", to: "acct-X|user-2", automatic: false, sameWorkspace: true)),
                       .switched(to: "Work", automatic: false, sameWorkspace: true))
        XCTAssertEqual(line(.switched(at: now, from: "acct-X|user-1", to: "acct-X|user-2", automatic: false, verified: false,
                                      sameWorkspace: true)),
                       .switched(to: "Work", automatic: false, verified: false, sameWorkspace: true))
        XCTAssertEqual(line(.switched(at: now, from: "acct-A|user-1", to: "acct-B|user-2", automatic: false)),
                       .switched(to: "Personal", automatic: false, sameWorkspace: false))
    }

    func testARecentSwitchIsShownForAnHour() {
        XCTAssertEqual(line(.switched(at: now.addingTimeInterval(-3_600), from: "acct-A|user-1", to: "acct-B|user-2", automatic: true)),
                       .switched(to: "Personal", automatic: true))
        XCTAssertNil(line(.switched(at: now.addingTimeInterval(-3_601), from: "acct-A|user-1", to: "acct-B|user-2", automatic: true)))
        XCTAssertNil(line(.paused(at: now)), "a paused status without the pause flag says nothing")
    }

    /// The card and Focus values the popover views take.
    func testCardAndFocusValues() {
        let id = UUID()
        let focus = CodexFocusLine(currentLabel: "Work", target: .init(accountID: id, label: "Personal"))
        XCTAssertEqual(focus.target?.accountID, id)
        XCTAssertNotEqual(focus, CodexFocusLine(currentLabel: "Work", target: nil))
        XCTAssertNotEqual(CodexCardState.current, .canSwitch(sameWorkspace: false))
        XCTAssertNotEqual(CodexCardState.canSwitch(sameWorkspace: true), .canSwitch(sameWorkspace: false))
        XCTAssertNotEqual(focus, CodexFocusLine(currentLabel: "Work",
                                                target: .init(accountID: id, label: "Personal", sameWorkspace: true)))
        XCTAssertEqual(focus.target?.sameWorkspace, false, "another workspace unless said")
    }
}
