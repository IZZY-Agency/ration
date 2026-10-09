import AppKit

/// Where the ring bar, its reveal strip and its hover card go. Pure: the real
/// frames come from `RingBarController`. Screen coordinates, origin bottom-left.
enum RingBarGeometry {
    /// Distance from the visible frame's edge (clear of the menu bar, the
    /// notch and a visible Dock).
    static let margin: CGFloat = 10
    /// The reveal strip's thickness at the PHYSICAL screen edge.
    static let activationThickness: CGFloat = 2
    /// How far the reveal strip and the keep zone reach past the bar's ends.
    static let activationOverhang: CGFloat = 24
    /// Space between the bar and its hover card.
    static let cardGap: CGFloat = 8
    /// The floating grip (the resize cue): this far off the bar's inner
    /// edge, this thick and long, with room around it for its shadow. All
    /// at scale 1: the grip grows with the bar.
    static let gripGap: CGFloat = 5
    static let gripThickness: CGFloat = 4
    static let gripLength: CGFloat = 24
    static let gripMargin: CGFloat = 3

    /// The longest the bar may be along its edge; longer content scrolls.
    static func maxLength(edge: RingBarEdge, visibleFrame: NSRect) -> CGFloat {
        max(0, (edge.isVertical ? visibleFrame.height : visibleFrame.width) - 2 * margin)
    }

    /// Centred on the edge, `margin` inside the visible frame, capped to
    /// `maxLength` along the edge.
    static func frame(edge: RingBarEdge, contentSize: NSSize, visibleFrame vf: NSRect) -> NSRect {
        let cap = maxLength(edge: edge, visibleFrame: vf)
        switch edge {
        case .left, .right:
            let height = min(contentSize.height, cap)
            let width = contentSize.width
            let x = edge == .left ? vf.minX + margin : vf.maxX - margin - width
            return NSRect(x: x, y: (vf.midY - height / 2).rounded(), width: width, height: height)
        case .top, .bottom:
            let width = min(contentSize.width, cap)
            let height = contentSize.height
            let y = edge == .bottom ? vf.minY + margin : vf.maxY - margin - height
            return NSRect(x: (vf.midX - width / 2).rounded(), y: y, width: width, height: height)
        }
    }

    /// The strip at the physical screen edge that reveals a bar hidden at
    /// the edge — the Dock's convention: you push the pointer against the edge.
    static func activationZone(edge: RingBarEdge, barFrame bar: NSRect, screenFrame s: NSRect) -> NSRect {
        let t = activationThickness, o = activationOverhang
        switch edge {
        case .left: return NSRect(x: s.minX, y: bar.minY - o, width: t, height: bar.height + 2 * o)
        case .right: return NSRect(x: s.maxX - t, y: bar.minY - o, width: t, height: bar.height + 2 * o)
        case .bottom: return NSRect(x: bar.minX - o, y: s.minY, width: bar.width + 2 * o, height: t)
        case .top: return NSRect(x: bar.minX - o, y: s.maxY - t, width: bar.width + 2 * o, height: t)
        }
    }

    /// Where the pointer keeps a revealed bar shown: the bar plus the
    /// corridor from the physical edge to it (the `margin` gap and, on that
    /// edge, a visible Dock).
    /// `reach` extends it past the bar's inner edge: over the grip strip
    /// while the grip shows, so reaching for it does not hide the bar.
    static func keepZone(edge: RingBarEdge, barFrame bar: NSRect, screenFrame s: NSRect, reach: CGFloat = 0) -> NSRect {
        let o = activationOverhang
        switch edge {
        case .left: return NSRect(x: s.minX, y: bar.minY - o, width: bar.maxX + reach - s.minX, height: bar.height + 2 * o)
        case .right: return NSRect(x: bar.minX - reach, y: bar.minY - o, width: s.maxX - bar.minX + reach, height: bar.height + 2 * o)
        case .bottom: return NSRect(x: bar.minX - o, y: s.minY, width: bar.width + 2 * o, height: bar.maxY + reach - s.minY)
        case .top: return NSRect(x: bar.minX - o, y: bar.minY - reach, width: bar.width + 2 * o, height: s.maxY - bar.minY + reach)
        }
    }

    /// How far the grip strip reaches off the bar.
    static func gripDepth(scale: Double) -> CGFloat {
        (gripGap + gripThickness + gripMargin) * scale
    }

    /// The strip along the bar's inner edge that holds the floating grip.
    static func gripLane(edge: RingBarEdge, barFrame bar: NSRect, scale: Double) -> NSRect {
        let depth = gripDepth(scale: scale)
        switch edge {
        case .left: return NSRect(x: bar.maxX, y: bar.minY, width: depth, height: bar.height)
        case .right: return NSRect(x: bar.minX - depth, y: bar.minY, width: depth, height: bar.height)
        case .bottom: return NSRect(x: bar.minX, y: bar.maxY, width: bar.width, height: depth)
        case .top: return NSRect(x: bar.minX, y: bar.minY - depth, width: bar.width, height: depth)
        }
    }

    /// One grip per glass segment, centred on it, `gripGap` off the bar.
    static func gripPills(edge: RingBarEdge, barFrame bar: NSRect, segmentFrames: [NSRect], scale: Double) -> [NSRect] {
        let gap = gripGap * scale, thickness = gripThickness * scale, length = gripLength * scale
        return segmentFrames.map { segment in
            switch edge {
            case .left: NSRect(x: bar.maxX + gap, y: segment.midY - length / 2, width: thickness, height: length)
            case .right: NSRect(x: bar.minX - gap - thickness, y: segment.midY - length / 2, width: thickness, height: length)
            case .bottom: NSRect(x: segment.midX - length / 2, y: bar.maxY + gap, width: length, height: thickness)
            case .top: NSRect(x: segment.midX - length / 2, y: bar.minY - gap - thickness, width: length, height: thickness)
            }
        }
    }

    /// Beside the bar toward the inside of the screen, level with the
    /// pointer, kept inside the visible frame.
    static func cardFrame(
        edge: RingBarEdge, cardSize c: NSSize, barFrame bar: NSRect, pointer p: NSPoint, visibleFrame vf: NSRect
    ) -> NSRect {
        var origin: NSPoint
        switch edge {
        case .left: origin = NSPoint(x: bar.maxX + cardGap, y: p.y - c.height / 2)
        case .right: origin = NSPoint(x: bar.minX - cardGap - c.width, y: p.y - c.height / 2)
        case .bottom: origin = NSPoint(x: p.x - c.width / 2, y: bar.maxY + cardGap)
        case .top: origin = NSPoint(x: p.x - c.width / 2, y: bar.minY - cardGap - c.height)
        }
        origin.x = min(max(origin.x, vf.minX + margin), vf.maxX - margin - c.width)
        origin.y = min(max(origin.y, vf.minY + margin), vf.maxY - margin - c.height)
        return NSRect(origin: origin, size: c)
    }

    /// `NSRect.contains` with its max edges included: the pointer can sit on
    /// a screen's last column or row.
    static func contains(_ rect: NSRect, _ point: NSPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX && point.y >= rect.minY && point.y <= rect.maxY
    }
}
