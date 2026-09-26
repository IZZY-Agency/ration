import XCTest
@testable import Ration

/// The problem badge's hover hint: shown after the delay under the badge it
/// was measured for, and dismissed when that badge moves (the list scrolled)
/// so it can never hang detached from it.
final class BadgeHintStateTests: XCTestCase {
    private let a = UUID()
    private let b = UUID()
    private let frameA = CGRect(x: 400, y: 120, width: 60, height: 16)
    private let frameB = CGRect(x: 400, y: 260, width: 60, height: 16)

    func testShowsAfterTheDelayUnderTheHoveredBadge() {
        var state = BadgeHintState()
        state.handle(.entered(frameA), for: a)
        XCTAssertNil(state.shown, "not before the delay")
        state.delayElapsed(for: a)
        XCTAssertEqual(state.shown, BadgeHint(id: a, frame: frameA))
    }

    func testLeavingHidesIt() {
        var state = BadgeHintState()
        state.handle(.entered(frameA), for: a)
        state.delayElapsed(for: a)
        state.handle(.exited, for: a)
        XCTAssertNil(state.shown)
        // A delay that elapses after leaving shows nothing.
        state.handle(.entered(frameA), for: a)
        state.handle(.exited, for: a)
        state.delayElapsed(for: a)
        XCTAssertNil(state.shown)
    }

    /// Scrolling moves the badge without a hover event: the hint goes.
    func testTheBadgeMovingDismissesIt() {
        var state = BadgeHintState()
        state.handle(.entered(frameA), for: a)
        state.delayElapsed(for: a)
        state.handle(.moved, for: a)
        XCTAssertNil(state.shown)

        // Moving while the delay is pending cancels it too.
        state.handle(.entered(frameA), for: a)
        state.handle(.moved, for: a)
        state.delayElapsed(for: a)
        XCTAssertNil(state.shown)
    }

    /// A late "left" from one badge cannot hide the hint another just
    /// brought up; another badge's delay cannot show a stale one.
    func testKeyedByAccount() {
        var state = BadgeHintState()
        state.handle(.entered(frameA), for: a)
        state.handle(.entered(frameB), for: b)
        state.handle(.exited, for: a)
        state.delayElapsed(for: a)
        XCTAssertNil(state.shown)
        state.delayElapsed(for: b)
        XCTAssertEqual(state.shown, BadgeHint(id: b, frame: frameB))
        state.handle(.moved, for: a)
        XCTAssertEqual(state.shown, BadgeHint(id: b, frame: frameB))
    }
}
