import AppKit
import XCTest
@testable import Ration

/// A resize gesture on the SwiftUI background never saw dividers and letters
/// (drawn in front) or the gaps between capsules (no SwiftUI at all). The
/// panel routes every press itself: anything but a gauge resizes.
@MainActor
final class RingBarDragRouterTests: XCTestCase {
    private var phases: [RingBarResizePhase] = []
    private var points: [NSPoint] = []
    private let gauge = NSRect(x: 100, y: 100, width: 30, height: 30)

    private func router(armed: Bool = true) -> RingBarDragRouter {
        let router = RingBarDragRouter()
        router.isOnGauge = { [gauge] in gauge.contains($0) }
        router.isArmed = { armed }
        router.onPhase = { [unowned self] phase, point in
            phases.append(phase)
            points.append(point)
        }
        return router
    }

    func testPressOnAGaugeIsLeftToTheGauge() {
        let r = router()
        XCTAssertFalse(r.mouseDown(at: NSPoint(x: 110, y: 110)))
        XCTAssertFalse(r.mouseDragged(at: NSPoint(x: 130, y: 110)))
        XCTAssertFalse(r.mouseUp(at: NSPoint(x: 130, y: 110)))
        XCTAssertTrue(phases.isEmpty)
    }

    func testDragOnEmptyGlassResizes() {
        let r = router()
        XCTAssertTrue(r.mouseDown(at: NSPoint(x: 50, y: 110)), "a divider, a letter, a gap: anything but a gauge")
        XCTAssertTrue(r.mouseDragged(at: NSPoint(x: 51, y: 110)))
        XCTAssertTrue(phases.isEmpty, "under the threshold nothing starts")
        XCTAssertTrue(r.mouseDragged(at: NSPoint(x: 60, y: 110)))
        XCTAssertTrue(r.mouseDragged(at: NSPoint(x: 70, y: 110)))
        XCTAssertTrue(r.mouseUp(at: NSPoint(x: 70, y: 110)))
        XCTAssertEqual(phases, [.began, .changed, .changed, .ended])
        XCTAssertEqual(points.map(\.x), [50, 60, 70, 70], "the drag starts where the glass was grabbed, not past the threshold")
    }

    func testPressWithoutMoveDoesNothing() {
        let r = router()
        XCTAssertTrue(r.mouseDown(at: NSPoint(x: 50, y: 110)))
        XCTAssertTrue(r.mouseUp(at: NSPoint(x: 50, y: 110)))
        XCTAssertTrue(phases.isEmpty)
    }

    /// A drag whose mouse-up never came must not keep eating the next
    /// presses.
    func testALostReleaseIsFinishedByTheNextPress() {
        let r = router()
        XCTAssertTrue(r.mouseDown(at: NSPoint(x: 50, y: 110)))
        XCTAssertTrue(r.mouseDragged(at: NSPoint(x: 60, y: 110)))
        XCTAssertFalse(r.mouseDown(at: NSPoint(x: 110, y: 110)), "a gauge press still goes to the gauge")
        XCTAssertEqual(phases, [.began, .changed, .ended])
        XCTAssertFalse(r.mouseDragged(at: NSPoint(x: 130, y: 110)))
        XCTAssertFalse(r.mouseUp(at: NSPoint(x: 130, y: 110)))
    }

    func testResetForgetsThePress() {
        let r = router()
        XCTAssertTrue(r.mouseDown(at: NSPoint(x: 50, y: 110)))
        r.reset()
        XCTAssertFalse(r.mouseDragged(at: NSPoint(x: 80, y: 110)))
        XCTAssertFalse(r.mouseUp(at: NSPoint(x: 80, y: 110)))
        XCTAssertTrue(phases.isEmpty)
    }

    func testNothingWhileInputIsNotArmed() {
        let r = router(armed: false)
        XCTAssertFalse(r.mouseDown(at: NSPoint(x: 50, y: 110)))
        XCTAssertFalse(r.mouseDragged(at: NSPoint(x: 80, y: 110)))
        XCTAssertTrue(phases.isEmpty)
    }

    func testPanelRoutesEventsThroughTheRouter() throws {
        let panel = RingBarPanel()
        panel.setFrame(NSRect(x: 0, y: 0, width: 200, height: 60), display: false)
        let r = router()
        r.isOnGauge = { _ in false }
        panel.dragRouter = r
        func event(_ type: NSEvent.EventType, _ x: CGFloat) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 30), modifierFlags: [], timestamp: 0,
                                             windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        panel.sendEvent(try event(.leftMouseDown, 20))
        panel.sendEvent(try event(.leftMouseDragged, 40))
        panel.sendEvent(try event(.leftMouseUp, 40))
        XCTAssertEqual(phases, [.began, .changed, .ended])
    }

    /// The bar's right-click menu: right-click and Control-click open it,
    /// anywhere on the bar, and never start a drag.
    func testRightAndControlClicksOpenTheMenuNotADrag() throws {
        let panel = RingBarPanel()
        panel.setFrame(NSRect(x: 0, y: 0, width: 200, height: 60), display: false)
        let r = router()
        r.isOnGauge = { _ in false }
        panel.dragRouter = r
        var menus = 0
        panel.onContextMenu = { _ in menus += 1 }
        func event(_ type: NSEvent.EventType, _ x: CGFloat, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: 30), modifierFlags: flags, timestamp: 0,
                                             windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        panel.sendEvent(try event(.rightMouseDown, 20))
        panel.sendEvent(try event(.leftMouseDown, 20, .control))
        panel.sendEvent(try event(.leftMouseDragged, 60, .control))
        panel.sendEvent(try event(.leftMouseUp, 60, .control))
        XCTAssertEqual(menus, 2)
        XCTAssertTrue(phases.isEmpty, "a Control-click is the menu, not a drag")
        panel.sendEvent(try event(.leftMouseDown, 20))
        panel.sendEvent(try event(.leftMouseDragged, 60))
        XCTAssertEqual(phases, [.began, .changed], "a plain press still drags")
    }

    func testAConsumedPressNeverReachesTheViews() throws {
        let panel = RingBarPanel()
        panel.setFrame(NSRect(x: 0, y: 0, width: 200, height: 60), display: false)
        let content = PressRecorder(frame: NSRect(x: 0, y: 0, width: 200, height: 60))
        panel.contentView = content
        // Off every screen: AppKit dispatches presses only to a window it shows.
        panel.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        panel.orderFrontRegardless()
        defer { panel.orderOut(nil) }
        var onGauge = false
        let r = router()
        r.isOnGauge = { _ in onGauge }
        panel.dragRouter = r
        func down() throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 20, y: 30), modifierFlags: [], timestamp: 0,
                                             windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        }
        panel.sendEvent(try down())
        XCTAssertEqual(content.presses, 0, "glass: the bar's, not a view's")
        onGauge = true
        panel.sendEvent(try down())
        XCTAssertEqual(content.presses, 1, "a gauge gets its press")
    }
}

private final class PressRecorder: NSView {
    var presses = 0
    /// Like the bar's hosting views: a non-key panel's first press reaches them.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { presses += 1 }
}
