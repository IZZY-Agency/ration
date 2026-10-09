import AppKit
import XCTest
@testable import Ration

/// Dragging the bar toward the screen's middle grows it, away shrinks it,
/// in proportion to the bar's thickness when the drag began.
final class RingBarResizeTests: XCTestCase {
    private let start = NSPoint(x: 500, y: 500)

    func testInwardIsTowardTheScreensMiddle() {
        XCTAssertEqual(RingBarResize.inward(.left, from: start, to: NSPoint(x: 520, y: 500)), 20)
        XCTAssertEqual(RingBarResize.inward(.right, from: start, to: NSPoint(x: 520, y: 500)), -20)
        XCTAssertEqual(RingBarResize.inward(.bottom, from: start, to: NSPoint(x: 500, y: 530)), 30)
        XCTAssertEqual(RingBarResize.inward(.top, from: start, to: NSPoint(x: 500, y: 530)), -30)
        XCTAssertEqual(RingBarResize.inward(.left, from: start, to: NSPoint(x: 500, y: 900)), 0, "along the bar does nothing")
    }

    func testScaleFollowsThickness() {
        XCTAssertEqual(RingBarResize.scale(startScale: 1, startThickness: 40, inward: 20), 1.5, accuracy: 0.0001)
        XCTAssertEqual(RingBarResize.scale(startScale: 1.2, startThickness: 48, inward: -8), 1.0, accuracy: 0.0001)
    }

    func testScaleIsClamped() {
        XCTAssertEqual(RingBarResize.scale(startScale: 1, startThickness: 40, inward: 400), 1.8)
        XCTAssertEqual(RingBarResize.scale(startScale: 1, startThickness: 40, inward: -400), 0.8)
    }

    func testZeroThicknessKeepsTheStart() {
        XCTAssertEqual(RingBarResize.scale(startScale: 1.3, startThickness: 0, inward: 50), 1.3)
    }
}
