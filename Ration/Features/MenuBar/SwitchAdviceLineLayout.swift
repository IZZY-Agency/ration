import SwiftUI

/// The popover header's advice line: arrow, lead ("SWITCH CLAUDE TO"),
/// target, tail ("· 85% OF WEEK LEFT"). The tail carries the number, so it is
/// never given up before the target: the target truncates first, down to a
/// small floor, and only then does the tail yield. HStack priorities cannot
/// express "shrink, but not below a floor" without padding a short target.
struct SwitchAdviceLineLayout: Layout {
    var spacing: CGFloat
    /// The least of the target name kept visible while the tail can still
    /// give way (a shorter name keeps its own width).
    static let targetFloor: CGFloat = 28

    /// Widths for target and tail, given everything else's ideal width.
    /// `available == nil` → ideal sizes.
    static func split(
        available: CGFloat?,
        spacing: CGFloat,
        fixed: CGFloat,
        targetIdeal: CGFloat,
        tailIdeal: CGFloat
    ) -> (target: CGFloat, tail: CGFloat) {
        guard let available else { return (targetIdeal, tailIdeal) }
        let gaps: CGFloat = spacing * 3
        let room: CGFloat = max(0, available - fixed - gaps)
        let floor: CGFloat = min(targetIdeal, targetFloor)
        let target: CGFloat = min(targetIdeal, max(floor, room - tailIdeal))
        let tail: CGFloat = min(tailIdeal, max(0, room - target))
        return (target, tail)
    }

    private struct Measured {
        var arrow: CGSize
        var lead: CGSize
        var target: CGFloat
        var tail: CGFloat
        var height: CGFloat
    }

    private func measure(_ available: CGFloat?, _ subviews: Subviews) -> Measured? {
        guard subviews.count == 4 else { return nil }
        let arrow: CGSize = subviews[0].sizeThatFits(.unspecified)
        let lead: CGSize = subviews[1].sizeThatFits(.unspecified)
        let targetIdeal: CGSize = subviews[2].sizeThatFits(.unspecified)
        let tailIdeal: CGSize = subviews[3].sizeThatFits(.unspecified)
        let fixed: CGFloat = arrow.width + lead.width
        let widths = Self.split(
            available: available,
            spacing: spacing,
            fixed: fixed,
            targetIdeal: targetIdeal.width,
            tailIdeal: tailIdeal.width
        )
        // A truncated target draws narrower than offered (it cuts at a
        // glyph); close that gap rather than leave it before the tail.
        let drawnTarget: CGFloat = subviews[2].sizeThatFits(ProposedViewSize(width: widths.target, height: nil)).width
        let target: CGFloat = min(drawnTarget, widths.target)
        var height: CGFloat = max(arrow.height, lead.height)
        height = max(height, max(targetIdeal.height, tailIdeal.height))
        return Measured(arrow: arrow, lead: lead, target: target, tail: widths.tail, height: height)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let m = measure(proposal.width, subviews) else { return .zero }
        var width: CGFloat = m.arrow.width + m.lead.width
        width += m.target + m.tail
        width += spacing * 3
        return CGSize(width: width, height: m.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let m = measure(bounds.width, subviews) else { return }
        let widths: [CGFloat] = [m.arrow.width, m.lead.width, m.target, m.tail]
        var x: CGFloat = bounds.minX
        for index in 0..<4 {
            subviews[index].place(
                at: CGPoint(x: x, y: bounds.midY),
                anchor: .leading,
                proposal: ProposedViewSize(width: widths[index], height: m.height)
            )
            x += widths[index] + spacing
        }
    }
}
