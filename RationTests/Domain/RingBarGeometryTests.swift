import AppKit
import XCTest
@testable import Ration

final class RingBarGeometryTests: XCTestCase {
    // A 16-inch MacBook Pro: 1728 × 1117 pt, menu bar 33 pt, Dock on the right (51 pt).
    private let screen = NSRect(x: 0, y: 0, width: 1728, height: 1117)
    private let visible = NSRect(x: 0, y: 0, width: 1677, height: 1084)

    func testLeftIsMarginInsideAndCentred() {
        let frame = RingBarGeometry.frame(edge: .left, contentSize: NSSize(width: 40, height: 348), visibleFrame: visible)
        XCTAssertEqual(frame, NSRect(x: 10, y: 368, width: 40, height: 348))
    }

    func testRightSitsBesideTheDock() {
        let frame = RingBarGeometry.frame(edge: .right, contentSize: NSSize(width: 40, height: 348), visibleFrame: visible)
        XCTAssertEqual(frame.maxX, 1667)
    }

    func testTopIsBelowTheMenuBarAndBottomAboveTheEdge() {
        let size = NSSize(width: 348, height: 40)
        XCTAssertEqual(RingBarGeometry.frame(edge: .top, contentSize: size, visibleFrame: visible).maxY, 1074)
        let bottom = RingBarGeometry.frame(edge: .bottom, contentSize: size, visibleFrame: visible)
        XCTAssertEqual(bottom.minY, 10)
        XCTAssertEqual(bottom.midX, visible.midX, accuracy: 0.5)
    }

    func testOverlongBarIsCappedToTheEdge() {
        let frame = RingBarGeometry.frame(edge: .left, contentSize: NSSize(width: 64, height: 5000), visibleFrame: visible)
        XCTAssertEqual(frame.height, 1064)
        XCTAssertEqual(frame.minY, 10)
        XCTAssertEqual(RingBarGeometry.maxLength(edge: .top, visibleFrame: visible), 1657)
    }

    func testActivationZoneIsThePhysicalEdge() {
        let bar = RingBarGeometry.frame(edge: .right, contentSize: NSSize(width: 40, height: 348), visibleFrame: visible)
        let zone = RingBarGeometry.activationZone(edge: .right, barFrame: bar, screenFrame: screen)
        XCTAssertEqual(zone.maxX, 1728)
        XCTAssertEqual(zone.width, 2)
        XCTAssertEqual(zone.minY, bar.minY - 24)
        XCTAssertTrue(RingBarGeometry.contains(zone, NSPoint(x: 1728, y: bar.midY)))
        XCTAssertFalse(RingBarGeometry.contains(zone, NSPoint(x: 1700, y: bar.midY)))
    }

    func testKeepZoneSpansCorridorAndBar() {
        let bar = RingBarGeometry.frame(edge: .left, contentSize: NSSize(width: 40, height: 348), visibleFrame: visible)
        let keep = RingBarGeometry.keepZone(edge: .left, barFrame: bar, screenFrame: screen)
        XCTAssertTrue(RingBarGeometry.contains(keep, NSPoint(x: 0, y: bar.midY)))
        XCTAssertTrue(RingBarGeometry.contains(keep, NSPoint(x: 5, y: bar.midY)))
        XCTAssertTrue(RingBarGeometry.contains(keep, NSPoint(x: bar.maxX, y: bar.midY)))
        XCTAssertFalse(RingBarGeometry.contains(keep, NSPoint(x: bar.maxX + 1, y: bar.midY)))
    }

    func testKeepZoneReachesOverTheGripStrip() {
        let bar = NSRect(x: 600, y: 10, width: 400, height: 60)
        let plain = RingBarGeometry.keepZone(edge: .bottom, barFrame: bar, screenFrame: screen)
        let reaching = RingBarGeometry.keepZone(edge: .bottom, barFrame: bar, screenFrame: screen, reach: 18)
        XCTAssertEqual(plain.maxY, bar.maxY)
        XCTAssertEqual(reaching.maxY, bar.maxY + 18)
        let right = NSRect(x: 1627, y: 368, width: 40, height: 348)
        XCTAssertEqual(RingBarGeometry.keepZone(edge: .right, barFrame: right, screenFrame: screen, reach: 18).minX, right.minX - 18)
        let top = NSRect(x: 600, y: 1014, width: 400, height: 60)
        XCTAssertEqual(RingBarGeometry.keepZone(edge: .top, barFrame: top, screenFrame: screen, reach: 18).minY, top.minY - 18)
        let left = NSRect(x: 10, y: 368, width: 40, height: 348)
        XCTAssertEqual(RingBarGeometry.keepZone(edge: .left, barFrame: left, screenFrame: screen, reach: 18).maxX, left.maxX + 18)
    }

    /// The grip floats 5 pt × the bar's scale off its inner edge, one per
    /// segment.
    func testGripsFloatOffTheInnerEdgeCentredOnEachSegment() {
        let scale = 1.5
        let gap = RingBarGeometry.gripGap * scale
        let bottom = NSRect(x: 600, y: 10, width: 400, height: 60)
        let segments = [NSRect(x: 600, y: 10, width: 150, height: 60), NSRect(x: 770, y: 10, width: 230, height: 60)]
        let pills = RingBarGeometry.gripPills(edge: .bottom, barFrame: bottom, segmentFrames: segments, scale: scale)
        XCTAssertEqual(pills.map(\.midX), segments.map(\.midX))
        XCTAssertEqual(pills.map(\.minY), [bottom.maxY + gap, bottom.maxY + gap], "5 pt × the bar's scale above it")
        XCTAssertEqual(pills.first?.width, RingBarGeometry.gripLength * scale)
        XCTAssertEqual(pills.first?.height, RingBarGeometry.gripThickness * scale)

        let left = NSRect(x: 10, y: 368, width: 40, height: 348)
        let leftPills = RingBarGeometry.gripPills(edge: .left, barFrame: left, segmentFrames: [left], scale: scale)
        XCTAssertEqual(leftPills.first?.minX, left.maxX + gap)
        XCTAssertEqual(leftPills.first?.midY, left.midY)
        let right = NSRect(x: 1627, y: 368, width: 40, height: 348)
        XCTAssertEqual(RingBarGeometry.gripPills(edge: .right, barFrame: right, segmentFrames: [right], scale: scale).first?.maxX,
                       right.minX - gap)
        let top = NSRect(x: 600, y: 1014, width: 400, height: 60)
        XCTAssertEqual(RingBarGeometry.gripPills(edge: .top, barFrame: top, segmentFrames: [top], scale: scale).first?.maxY,
                       top.minY - gap)
    }

    func testGripLaneHoldsThePillsAndTouchesTheBar() {
        for (edge, bar) in [(RingBarEdge.bottom, NSRect(x: 600, y: 10, width: 400, height: 60)),
                            (.top, NSRect(x: 600, y: 1014, width: 400, height: 60)),
                            (.left, NSRect(x: 10, y: 368, width: 40, height: 348)),
                            (.right, NSRect(x: 1627, y: 368, width: 40, height: 348))] {
            let lane = RingBarGeometry.gripLane(edge: edge, barFrame: bar, scale: 1.2)
            let pill = RingBarGeometry.gripPills(edge: edge, barFrame: bar, segmentFrames: [bar], scale: 1.2)[0]
            XCTAssertTrue(lane.contains(pill), "\(edge)")
            XCTAssertFalse(lane.intersects(bar), "\(edge): beside the bar, not over it")
            XCTAssertEqual(lane.union(bar).width * lane.union(bar).height, lane.width * lane.height + bar.width * bar.height,
                           accuracy: 0.01, "\(edge): no gap between bar and strip")
        }
    }

    func testCardGoesInsideTheScreenAndStaysVisible() {
        let bar = NSRect(x: 10, y: 368, width: 40, height: 348)
        let card = RingBarGeometry.cardFrame(edge: .left, cardSize: NSSize(width: 280, height: 120), barFrame: bar,
                                             pointer: NSPoint(x: 30, y: 1050), visibleFrame: visible)
        XCTAssertEqual(card.minX, bar.maxX + RingBarGeometry.cardGap)
        XCTAssertLessThanOrEqual(card.maxY, visible.maxY)
        let bottom = NSRect(x: 600, y: 10, width: 400, height: 40)
        let up = RingBarGeometry.cardFrame(edge: .bottom, cardSize: NSSize(width: 280, height: 120), barFrame: bottom,
                                           pointer: NSPoint(x: 990, y: 30), visibleFrame: visible)
        XCTAssertEqual(up.minY, bottom.maxY + RingBarGeometry.cardGap)
        let right = NSRect(x: 1627, y: 368, width: 40, height: 348)
        let left = RingBarGeometry.cardFrame(edge: .right, cardSize: NSSize(width: 280, height: 120), barFrame: right,
                                             pointer: NSPoint(x: 1640, y: 500), visibleFrame: visible)
        XCTAssertEqual(left.maxX, right.minX - RingBarGeometry.cardGap)
    }
}
