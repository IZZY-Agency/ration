import AppKit

/// Dragging empty glass on the ring bar, like the Dock's divider: toward
/// the screen's middle grows the bar, away shrinks it, in proportion to the
/// bar's thickness when the drag began, so its inner edge follows the
/// pointer. Screen coordinates (origin bottom-left).
enum RingBarResize {
    /// The pointer's movement toward the screen's middle, across the bar.
    static func inward(_ edge: RingBarEdge, from start: NSPoint, to now: NSPoint) -> CGFloat {
        switch edge {
        case .left: now.x - start.x
        case .right: start.x - now.x
        case .bottom: now.y - start.y
        case .top: start.y - now.y
        }
    }

    static func scale(startScale: Double, startThickness: CGFloat, inward: CGFloat) -> Double {
        guard startThickness > 0 else { return startScale }
        return AppSettingsData.clampedScale(startScale * Double((startThickness + inward) / startThickness))
    }
}
