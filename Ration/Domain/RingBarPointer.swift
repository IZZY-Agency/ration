import Foundation

/// The pointer the ring bar asks for: the Dock's resize pointer while the
/// pointer is on empty glass (where a press resizes), the arrow back when it
/// leaves. Shown by `RingBarCursor`.
enum RingBarPointer: Equatable, Sendable {
    case arrow
    /// Arrows across the bar's edge, only toward the sizes left to reach.
    case resize(edge: RingBarEdge, grows: Bool, shrinks: Bool)

    enum Arrow: Hashable, Sendable {
        case up, down, left, right
    }

    static func resize(edge: RingBarEdge, scale: Double) -> RingBarPointer {
        // A drag clamps to the limit; a hair short of it counts as there.
        let range = AppSettingsData.ringBarScaleRange
        return .resize(edge: edge, grows: scale < range.upperBound - 0.001, shrinks: scale > range.lowerBound + 0.001)
    }

    /// Screen directions; growing is toward the screen's middle.
    var arrows: Set<Arrow> {
        guard case let .resize(edge, grows, shrinks) = self else { return [] }
        let (inward, outward): (Arrow, Arrow) = switch edge {
        case .bottom: (.up, .down)
        case .top: (.down, .up)
        case .left: (.right, .left)
        case .right: (.left, .right)
        }
        var arrows: Set<Arrow> = []
        if grows { arrows.insert(inward) }
        if shrinks { arrows.insert(outward) }
        return arrows
    }
}
