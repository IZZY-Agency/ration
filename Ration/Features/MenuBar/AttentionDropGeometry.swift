import AppKit

/// Where the attention drop panel goes.
///
/// A pure function of frames, deliberately separated from the panel itself so
/// placement is unit-testable without a window server — the panel class then
/// only has to hand it real frames and set what it returns.
enum AttentionDropGeometry {
    /// Gap between the menu bar and the top of the panel.
    static let menuBarGap: CGFloat = 6
    /// Inset from the screen edge when the panel would otherwise touch it.
    static let screenEdgeInset: CGFloat = 8

    /// Fixed height of one crossing row. Pinned rather than left to intrinsic
    /// sizing so the panel height is an exact multiple of it rather than
    /// something only measurable after layout. 34 leaves the tallest line in
    /// a row (Space Mono Bold 14.5, 21pt line) 6.5pt of air above and below.
    static let rowHeight: CGFloat = 34

    /// Width of the trailing countdown column in a row. Fixed so the meters
    /// line up; sized to the widest string the formatters really produce —
    /// seven characters ("23h 59m", "30d 23h") in Space Mono 13, which
    /// measures 55.7pt — rounded up plus 2pt of slack.
    static let countdownColumnWidth: CGFloat = 58

    /// Narrowest a row's meter may get. The account label outranks it for
    /// space, and without a floor a long label left a 2 pt dot.
    static let meterMinWidth: CGFloat = 28

    /// Height of the rows area.
    ///
    /// Every crossing is shown — the drop's job is to say what is over a
    /// threshold right now, and hiding some behind a scroll defeats that at a
    /// glance — UNTIL the panel would outgrow the display. Past that the area
    /// is capped to a whole number of rows and scrolls.
    ///
    /// Clamping only the window (which `frame` still does) is not enough: the
    /// overflowing rows stay in the view tree, drawn below the visible bounds,
    /// with no way to reach them.
    ///
    /// `availableHeight` is the room left for rows on the target screen once
    /// the panel's own chrome is accounted for. At least one row always
    /// survives, however little is offered.
    static func rowsAreaHeight(rowCount: Int, availableHeight: CGFloat) -> CGFloat {
        let wanted = max(rowCount, 0)
        guard wanted > 0 else { return 0 }
        // Unbounded (the model's initial `.greatestFiniteMagnitude`, or not a
        // number at all) means "no cap" — and `Int(_:)` would trap on it.
        guard availableHeight.isFinite, availableHeight < CGFloat(wanted) * rowHeight else {
            return CGFloat(wanted) * rowHeight
        }
        let fits = max(1, Int(availableHeight / rowHeight))
        return CGFloat(min(wanted, fits)) * rowHeight
    }

    /// Whether the rows area needs to scroll to reach everything.
    static func rowsScroll(rowCount: Int, availableHeight: CGFloat) -> Bool {
        rowsAreaHeight(rowCount: rowCount, availableHeight: availableHeight)
            < CGFloat(max(rowCount, 0)) * rowHeight
    }

    /// Room left for rows on `visibleFrame` once the panel's chrome (ticker,
    /// header, divider, padding) is taken out.
    static func availableRowsHeight(visibleFrame: NSRect) -> CGFloat {
        max(rowHeight, visibleFrame.height - menuBarGap - chromeAllowance)
    }

    /// Ticker + header + divider + the rows area's own vertical padding.
    /// Deliberately generous: over-reserving costs one row, under-reserving
    /// puts the last row under the screen edge. At the +2pt sizes the real
    /// chrome is ≈42pt: ticker 7 + header 34 (the 22pt ✕ hit target outgrows
    /// the 16pt Space Mono 11 line, plus 6pt padding top and bottom) +
    /// divider 1 — so 60 still leaves ~18pt of margin.
    static let chromeAllowance: CGFloat = 60

    enum Anchor: Equatable {
        /// Hang under this status-item button frame (screen coordinates).
        case statusItem(NSRect)
        /// No usable status item — sit at the top trailing corner instead. The
        /// panel does not draw its ▲ ticker in this case, because there is
        /// nothing for it to point at.
        case screenTrailing
    }

    /// The display to place on: the one containing the button, or the main
    /// screen when there is no usable frame — including a frame that belongs
    /// to no current screen, which is what a display being unplugged leaves
    /// behind.
    static func screen(forButtonFrame frame: NSRect?, screens: [NSRect], main: NSRect) -> NSRect {
        guard let frame else { return main }
        return screens.first { $0.intersects(frame) } ?? main
    }

    /// Whether there is a status item worth pointing at.
    ///
    /// The frame must be non-empty AND intersect this screen's menu-bar strip.
    /// Both halves are load-bearing: for roughly a third of a second after the
    /// status item is created, its button frame reads (0, -11, 54, 22) —
    /// non-empty, but nowhere near the menu bar (measured on this machine). An
    /// `isEmpty` check alone would sail past that and anchor the panel to the
    /// bottom-left corner of the display. An empty frame, meanwhile, is what
    /// the menu bar reports for an item parked behind the overflow chevron.
    static func anchor(
        buttonFrameInScreen frame: NSRect?,
        screen: NSRect,
        visibleFrame: NSRect
    ) -> Anchor {
        guard let frame, !frame.isEmpty else { return .screenTrailing }
        let menuBarStrip = NSRect(
            x: screen.minX,
            y: visibleFrame.maxY,
            width: screen.width,
            height: max(0, screen.maxY - visibleFrame.maxY)
        )
        return menuBarStrip.intersects(frame) ? .statusItem(frame) : .screenTrailing
    }

    /// The final panel frame, always clamped inside `visibleFrame` so a status
    /// item near a screen edge — or a panel taller than the display — can
    /// never push it off.
    static func frame(
        anchor: Anchor,
        screen: NSRect,
        visibleFrame: NSRect,
        panelSize: NSSize
    ) -> NSRect {
        let top = visibleFrame.maxY - menuBarGap
        let height = min(panelSize.height, visibleFrame.height)

        let unclampedX: CGFloat
        switch anchor {
        case .statusItem(let button):
            unclampedX = button.midX - panelSize.width / 2
        case .screenTrailing:
            unclampedX = visibleFrame.maxX - screenEdgeInset - panelSize.width
        }

        let minX = visibleFrame.minX + screenEdgeInset
        let maxX = visibleFrame.maxX - screenEdgeInset - panelSize.width
        // `max(minX, ...)` last so a panel wider than the screen still starts
        // on-screen rather than being pushed off the left edge by the clamp.
        let x = max(min(unclampedX, maxX), minX)
        let y = max(top - height, visibleFrame.minY)

        return NSRect(x: x, y: y, width: panelSize.width, height: height)
    }
}
