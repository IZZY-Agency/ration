import AppKit
import XCTest
@testable import Ration

/// Panel placement is a pure function of frames so it can be tested without a
/// window server. The numbers here are REAL ones measured from a running
/// status item on this machine (1728×1117 display, menu bar 33pt tall, button
/// at x=939) rather than invented round figures.
final class AttentionDropGeometryTests: XCTestCase {
    /// A 1728×1117 display whose menu bar occupies the top 33pt.
    private let screen = NSRect(x: 0, y: 0, width: 1728, height: 1117)
    private let visible = NSRect(x: 0, y: 0, width: 1728, height: 1084)
    private let panelSize = NSSize(width: 320, height: 140)

    /// The measured frame of a real status-item button, in screen coordinates.
    private let buttonFrame = NSRect(x: 939, y: 1089.5, width: 54, height: 22)

    // MARK: - Screen selection

    func testPicksTheScreenContainingTheButton() {
        let second = NSRect(x: -1512, y: 0, width: 1512, height: 982)
        XCTAssertEqual(
            AttentionDropGeometry.screen(
                forButtonFrame: NSRect(x: -600, y: 940, width: 54, height: 22),
                screens: [screen, second],
                main: screen
            ),
            second
        )
    }

    func testFallsBackToTheMainScreenWithoutAButtonFrame() {
        XCTAssertEqual(
            AttentionDropGeometry.screen(forButtonFrame: nil, screens: [screen], main: screen),
            screen
        )
    }

    /// A frame on no known screen (a display that just went away) must not
    /// leave the panel homeless.
    func testFallsBackToTheMainScreenForAnOffScreenButtonFrame() {
        XCTAssertEqual(
            AttentionDropGeometry.screen(
                forButtonFrame: NSRect(x: -9_000, y: -9_000, width: 54, height: 22),
                screens: [screen],
                main: screen
            ),
            screen
        )
    }

    // MARK: - Anchor

    func testAnchorsToTheStatusItemWhenTheButtonIsInTheMenuBar() {
        XCTAssertEqual(
            AttentionDropGeometry.anchor(
                buttonFrameInScreen: buttonFrame,
                screen: screen,
                visibleFrame: visible
            ),
            .statusItem(buttonFrame)
        )
    }

    /// The measured hazard: for roughly a third of a second after the status
    /// item is created, its button frame reads (0, -11, 54, 22) — NON-EMPTY,
    /// but nowhere near the menu bar. An `isEmpty` guard alone would sail past
    /// this and anchor the panel to the bottom-left corner of the display.
    func testDoesNotAnchorToANonEmptyButUnlaidOutButtonFrame() {
        XCTAssertEqual(
            AttentionDropGeometry.anchor(
                buttonFrameInScreen: NSRect(x: 0, y: -11, width: 54, height: 22),
                screen: screen,
                visibleFrame: visible
            ),
            .screenTrailing,
            "a frame outside the menu-bar strip is not an anchor, empty or not"
        )
    }

    func testFallsBackToScreenTrailingWithoutAButtonFrame() {
        XCTAssertEqual(
            AttentionDropGeometry.anchor(
                buttonFrameInScreen: nil,
                screen: screen,
                visibleFrame: visible
            ),
            .screenTrailing
        )
    }

    /// An empty frame is what the menu bar reports for an item parked behind
    /// the overflow chevron; there is nothing to point at.
    func testFallsBackToScreenTrailingForAnEmptyButtonFrame() {
        XCTAssertEqual(
            AttentionDropGeometry.anchor(
                buttonFrameInScreen: .zero,
                screen: screen,
                visibleFrame: visible
            ),
            .screenTrailing
        )
    }

    // MARK: - Frame

    func testStatusItemAnchorCentersThePanelUnderTheButton() {
        let frame = AttentionDropGeometry.frame(
            anchor: .statusItem(buttonFrame),
            screen: screen,
            visibleFrame: visible,
            panelSize: panelSize
        )
        XCTAssertEqual(frame.width, panelSize.width)
        XCTAssertEqual(frame.height, panelSize.height)
        XCTAssertEqual(frame.midX, buttonFrame.midX, accuracy: 0.5)
        XCTAssertEqual(
            frame.maxY,
            visible.maxY - AttentionDropGeometry.menuBarGap,
            accuracy: 0.5,
            "the panel hangs just below the menu bar"
        )
    }

    func testScreenTrailingAnchorSitsAtTheTopRight() {
        let frame = AttentionDropGeometry.frame(
            anchor: .screenTrailing,
            screen: screen,
            visibleFrame: visible,
            panelSize: panelSize
        )
        XCTAssertEqual(
            frame.maxX,
            visible.maxX - AttentionDropGeometry.screenEdgeInset,
            accuracy: 0.5
        )
        XCTAssertEqual(
            frame.maxY,
            visible.maxY - AttentionDropGeometry.menuBarGap,
            accuracy: 0.5
        )
    }

    /// A status item near the right edge must not push the panel off-screen.
    func testFrameIsClampedToTheRightEdge() {
        let nearEdge = NSRect(x: 1700, y: 1089.5, width: 20, height: 22)
        let frame = AttentionDropGeometry.frame(
            anchor: .statusItem(nearEdge),
            screen: screen,
            visibleFrame: visible,
            panelSize: panelSize
        )
        XCTAssertLessThanOrEqual(
            frame.maxX,
            visible.maxX - AttentionDropGeometry.screenEdgeInset + 0.5
        )
        XCTAssertGreaterThanOrEqual(frame.minX, visible.minX)
    }

    /// ...and the same on the left, for a display whose origin is negative.
    func testFrameIsClampedToTheLeftEdge() {
        let leftScreen = NSRect(x: -1512, y: 0, width: 1512, height: 982)
        let leftVisible = NSRect(x: -1512, y: 0, width: 1512, height: 949)
        let nearEdge = NSRect(x: -1508, y: 955, width: 20, height: 22)
        let frame = AttentionDropGeometry.frame(
            anchor: .statusItem(nearEdge),
            screen: leftScreen,
            visibleFrame: leftVisible,
            panelSize: panelSize
        )
        XCTAssertGreaterThanOrEqual(
            frame.minX,
            leftVisible.minX + AttentionDropGeometry.screenEdgeInset - 0.5
        )
        XCTAssertLessThanOrEqual(frame.maxX, leftVisible.maxX)
    }

    /// A panel taller than the screen must still start below the menu bar and
    /// stay on the display rather than running off the bottom.
    func testAnOverlyTallPanelStaysWithinTheVisibleFrame() {
        let frame = AttentionDropGeometry.frame(
            anchor: .statusItem(buttonFrame),
            screen: screen,
            visibleFrame: visible,
            panelSize: NSSize(width: 320, height: 5_000)
        )
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY)
    }

    // MARK: - Rows area height

    /// EVERY crossing is shown — the drop exists to say what is over a
    /// threshold right now, and hiding some behind a scroll defeats that.
    func testRowsAreaGrowsWithEveryRow() {
        for count in [1, 2, 4, 7, 12] {
            XCTAssertEqual(
                AttentionDropGeometry.rowsAreaHeight(rowCount: count, availableHeight: 10_000),
                AttentionDropGeometry.rowHeight * CGFloat(count),
                accuracy: 0.01,
                "row \(count) must add its own height"
            )
        }
    }

    func testEmptyRowsAreaIsZero() {
        XCTAssertEqual(
            AttentionDropGeometry.rowsAreaHeight(rowCount: 0, availableHeight: 10_000),
            0,
            accuracy: 0.01
        )
    }

    /// A negative count is nonsense but must not produce a negative frame.
    func testNegativeRowCountClampsToZero() {
        XCTAssertEqual(
            AttentionDropGeometry.rowsAreaHeight(rowCount: -3, availableHeight: 10_000),
            0,
            accuracy: 0.01
        )
    }

    // MARK: - Overflowing the screen

    /// Every crossing is shown UNTIL the panel would outgrow the display.
    /// Past that the rows area is capped to what fits and scrolls — clamping
    /// the window alone left the bottom rows drawn but unreachable.
    func testRowsAreaIsCappedToWhatTheScreenCanHold() {
        let available: CGFloat = 300
        let manyRows = 40
        let height = AttentionDropGeometry.rowsAreaHeight(
            rowCount: manyRows,
            availableHeight: available
        )
        XCTAssertLessThanOrEqual(height, available)
        XCTAssertTrue(AttentionDropGeometry.rowsScroll(rowCount: manyRows, availableHeight: available))
        // Whole rows only — a half-row peeking out reads as a rendering bug.
        XCTAssertEqual(
            height.truncatingRemainder(dividingBy: AttentionDropGeometry.rowHeight),
            0,
            accuracy: 0.01
        )
    }

    /// Below that point nothing is capped and nothing scrolls.
    func testRowsAreaIsUncappedWhenEverythingFits() {
        let available: CGFloat = 1_000
        XCTAssertEqual(
            AttentionDropGeometry.rowsAreaHeight(rowCount: 6, availableHeight: available),
            AttentionDropGeometry.rowHeight * 6,
            accuracy: 0.01
        )
        XCTAssertFalse(AttentionDropGeometry.rowsScroll(rowCount: 6, availableHeight: available))
    }

    /// Even an absurdly short allowance must leave one row visible rather than
    /// collapsing the panel to nothing.
    func testAtLeastOneRowSurvivesATinyAllowance() {
        XCTAssertEqual(
            AttentionDropGeometry.rowsAreaHeight(rowCount: 9, availableHeight: 4),
            AttentionDropGeometry.rowHeight,
            accuracy: 0.01
        )
    }

    /// Showing everything is only safe because the frame still clamps: a
    /// pathological number of crossings must not run off the display.
    func testAVeryTallPanelIsStillClampedToTheScreen() {
        let tall = AttentionDropGeometry.rowsAreaHeight(rowCount: 200, availableHeight: 10_000) + 60
        let frame = AttentionDropGeometry.frame(
            anchor: .statusItem(buttonFrame),
            screen: screen,
            visibleFrame: visible,
            panelSize: NSSize(width: 320, height: tall)
        )
        XCTAssertGreaterThanOrEqual(frame.minY, visible.minY)
        XCTAssertLessThanOrEqual(frame.maxY, visible.maxY)
    }
}
