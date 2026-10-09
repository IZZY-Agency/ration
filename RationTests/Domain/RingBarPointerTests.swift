import XCTest
@testable import Ration

/// Over empty glass the bar shows the Dock's resize pointer, its arrows
/// across the bar's edge, only toward the sizes left to reach: dragging the
/// bar is not discoverable without it.
final class RingBarPointerTests: XCTestCase {
    func testLimitsLeaveOneArrow() {
        XCTAssertEqual(RingBarPointer.resize(edge: .bottom, scale: 1), .resize(edge: .bottom, grows: true, shrinks: true))
        XCTAssertEqual(RingBarPointer.resize(edge: .bottom, scale: 1.8), .resize(edge: .bottom, grows: false, shrinks: true))
        XCTAssertEqual(RingBarPointer.resize(edge: .bottom, scale: 0.8), .resize(edge: .bottom, grows: true, shrinks: false))
        XCTAssertEqual(RingBarPointer.resize(edge: .left, scale: 1.7999), .resize(edge: .left, grows: false, shrinks: true),
                       "a drag clamps to the limit, a hair short of it counts")
    }

    func testArrowsPointAcrossTheEdge() {
        XCTAssertEqual(RingBarPointer.resize(edge: .bottom, grows: true, shrinks: true).arrows, [.up, .down])
        XCTAssertEqual(RingBarPointer.resize(edge: .bottom, grows: true, shrinks: false).arrows, [.up], "grow = toward the middle")
        XCTAssertEqual(RingBarPointer.resize(edge: .top, grows: true, shrinks: false).arrows, [.down])
        XCTAssertEqual(RingBarPointer.resize(edge: .left, grows: true, shrinks: false).arrows, [.right])
        XCTAssertEqual(RingBarPointer.resize(edge: .right, grows: true, shrinks: false).arrows, [.left])
        XCTAssertEqual(RingBarPointer.resize(edge: .right, grows: false, shrinks: true).arrows, [.right])
        XCTAssertEqual(RingBarPointer.arrow.arrows, [])
    }
}
