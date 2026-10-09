import AppKit
import SwiftUI

/// The bar's sizes at scale 1; every view multiplies by `RingBarModel.scale`
/// (dragged on the bar or set with Settings › Display › Size).
enum RingBarMetrics {
    static func side(_ style: RingBarStyle, scale: Double = 1) -> CGFloat { (style == .rail ? 20 : 30) * scale }
    static func stroke(_ style: RingBarStyle, scale: Double = 1) -> CGFloat { (style == .rail ? 3 : 3.5) * scale }
    static func capsuleCellWidth(scale: Double = 1) -> CGFloat { 50 * scale }
    static func padding(scale: Double = 1) -> CGFloat { 9 * scale }
    static func spacing(scale: Double = 1) -> CGFloat { 7 * scale }
    /// How far the glass is tinted toward the ink colour: over a light
    /// window untinted glass turned mid-grey and its text fell to 1.5:1.
    static let glassTint: CGFloat = 0.4
    /// An ink layer inside each glass, under the gauges. The glass's own
    /// tint barely darkened it over a white window (measured #B2B2B2, cream
    /// text 1.7:1); this is a plain overlay, so it darkens the same over
    /// anything.
    static let glassShade: CGFloat = 0.6
    /// One instance: the ink of the panel's appearance, at `glassTint`.
    static let glassTintColor: NSColor = Theme.inkNS.withAlphaComponent(glassTint)
    /// Between the glass of subscriptions and the glass of API keys.
    static func kindGap(scale: Double = 1) -> CGFloat { 20 * scale }
    /// A rail is one strip, a capsule one per provider; both round off at
    /// half their thickness.
    static func cornerRadius(_ style: RingBarStyle, scale: Double = 1) -> CGFloat { (style == .rail ? 19 : 18) * scale }
    /// The hover card keeps its size: it is text to read, not a gauge.
    static let cardWidth: CGFloat = 280
    /// A gauge cell's padding; the hover highlight reaches past it to
    /// `highlightMargin` around the drawing (into the glass's padding).
    static func cellPadding(scale: Double = 1) -> CGFloat { 2 * scale }
    static func highlightMargin(_ style: RingBarStyle, scale: Double = 1) -> CGFloat { (style == .rail ? 2 : 4) * scale }
    /// A label's line box runs below its baseline by the font's descent;
    /// the highlight comes up by it, so the margin under the text matches
    /// the others (Space Grotesk, or Manrope in Ukrainian).
    static func labelDescent(scale: Double = 1) -> CGFloat {
        let size = labelSize * scale
        let font = NSFont(name: Theme.DisplayWeight.medium.postScriptName(for: .current), size: size)
        return font.map { -$0.descender } ?? 0.27 * size
    }
    static let labelSize: CGFloat = 10
}

/// Each gauge's frame in its segment, for the controller's hit test.
struct RingBarCellFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// One glass segment's content: the whole rail, or one provider's capsule.
/// Reads its groups from the model by source, so data updates never rebuild it.
struct RingBarSegmentView: View {
    @ObservedObject var model: RingBarModel
    let sources: [DisplaySource]
    /// This segment's index, for `RingBarModel.cellFrames`.
    let segment: Int

    static let space = "ringBarSegment"

    var body: some View {
        let groups = sources.compactMap(model.group)
        let scale = model.scale
        stack(scale: scale) {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 { divider(scale: scale) }
                mark(group.source, scale: scale)
                ForEach(group.entries) { entry in
                    RingBarGaugeCell(
                        entry: entry,
                        source: group.source,
                        style: model.style,
                        scale: scale,
                        displaysRemaining: model.displaysRemaining,
                        now: model.now,
                        isHovered: model.hoveredID == entry.id,
                        onSelect: { model.onSelect(entry.id) }
                    )
                    .background(GeometryReader { geometry in
                        Color.clear.preference(
                            key: RingBarCellFrames.self,
                            value: [entry.id: geometry.frame(in: .named(Self.space))]
                        )
                    })
                }
            }
        }
        .padding(RingBarMetrics.padding(scale: scale))
        // The glass under it darkens the same over any window: text and
        // gauges stay legible over a white page (`glassShade`).
        .background(
            RoundedRectangle(cornerRadius: RingBarMetrics.cornerRadius(model.style, scale: scale))
                .fill(Theme.ink.opacity(RingBarMetrics.glassShade))
        )
        .fixedSize()
        // Resizing (a press on anything but a gauge) is routed by the panel
        // itself (`RingBarDragRouter`): dividers and letters sit in front of
        // any SwiftUI background, and the gaps between capsules have none.
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(RingBarCellFrames.self) { frames in
            MainActor.assumeIsolated { model.reportFrames(frames, segment: segment) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(groups.map(\.source.displayName).joined(separator: ", "))
    }

    @ViewBuilder
    private func stack<Content: View>(scale: Double, @ViewBuilder _ content: () -> Content) -> some View {
        if model.edge.isVertical {
            VStack(spacing: RingBarMetrics.spacing(scale: scale)) { content() }
        } else {
            HStack(alignment: model.style == .capsules ? .top : .center, spacing: RingBarMetrics.spacing(scale: scale)) { content() }
        }
    }

    /// The provider's letter (C, G, A, O, T) before its gauges; the capsule
    /// draws it as a chip.
    private func mark(_ source: DisplaySource, scale: Double) -> some View {
        let capsule = model.style == .capsules
        return Text(verbatim: source.markLetter)
            .font(Theme.mono((capsule ? 9.5 : 10) * scale, bold: true))
            .foregroundStyle(source.accent)
            .frame(width: (capsule ? 18 : 20) * scale, height: (capsule ? 18 : 12) * scale)
            .background {
                if capsule {
                    RoundedRectangle(cornerRadius: 6 * scale).fill(source.accent.opacity(0.2))
                }
            }
            .padding(.top, capsule && !model.edge.isVertical ? 6 * scale : 0)
            .accessibilityHidden(true)
    }

    /// A hairline between providers; each kind has its own glass, so this
    /// never separates plans from API keys. Across the stack: a ring's height
    /// on the rail, a gauge cell's on a capsule tray.
    private func divider(scale: Double) -> some View {
        let vertical = model.edge.isVertical
        let capsules = model.style == .capsules
        let length = (capsules ? 40 : 18) * scale
        return Rectangle()
            .fill(Theme.line2)
            .frame(width: vertical ? length : 1 * scale, height: vertical ? 1 * scale : length)
            .padding(vertical ? .vertical : .horizontal, (capsules ? 4 : 1) * scale)
            // Capsule trays align to the top (the chips); centre the line on the cells.
            .padding(.top, capsules && !vertical ? 5 * scale : 0)
            .accessibilityHidden(true)
    }
}

/// Offers its content at most `width` and takes the content's own size: a
/// label that hugs its text and truncates past `width`. (`frame(maxWidth:)`
/// would widen a short label to `width`, and the hover highlight with it.)
struct RingBarCappedWidth: Layout {
    let width: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        return content.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? width, width), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

/// One gauge: the menu bar's drawing at the bar's size. Capsules add the
/// value inside and the account name under it, and move the in-use dot to
/// the corner (the value takes the centre).
struct RingBarGaugeCell: View {
    let entry: GaugeEntry
    let source: DisplaySource
    let style: RingBarStyle
    var scale: Double = 1
    let displaysRemaining: Bool
    let now: Date
    let isHovered: Bool
    let onSelect: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let padding = RingBarMetrics.cellPadding(scale: scale)
        let reach = RingBarMetrics.highlightMargin(style, scale: scale) - padding
        let descent = style == .capsules ? RingBarMetrics.labelDescent(scale: scale) : 0
        return Button(action: onSelect) {
            VStack(spacing: 3 * scale) {
                ZStack(alignment: .topTrailing) {
                    Image(nsImage: gaugeImage)
                        .overlay {
                            if style == .capsules {
                                Text(verbatim: "\(RingBarText.percent(for: entry.gauge, displaysRemaining: displaysRemaining))")
                                    .font(Theme.mono(9.5 * scale, bold: true))
                                    .monospacedDigit()
                                    .foregroundStyle(Theme.cream)
                                    .minimumScaleFactor(0.7)
                                    .lineLimit(1)
                            }
                        }
                    if style == .capsules && entry.gauge.inUse {
                        Circle()
                            .fill(Theme.active)
                            .frame(width: 8 * scale, height: 8 * scale)
                            .overlay(Circle().stroke(Theme.ink, lineWidth: 2 * scale))
                            .offset(x: 2 * scale, y: -2 * scale)
                    }
                }
                if style == .capsules {
                    RingBarCappedWidth(width: RingBarMetrics.capsuleCellWidth(scale: scale)) {
                        Text(verbatim: RingBarText.shortLabel(entry.gauge.label, in: source))
                            .font(Theme.display(RingBarMetrics.labelSize * scale))
                            // Cream, not dim grey: legible on the tinted glass over any window.
                            .foregroundStyle(Theme.cream)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .padding(padding)
            // Hugs the ring and label with one margin on every side; the
            // cell keeps its width below, so labels still line up.
            .background(
                RoundedRectangle(cornerRadius: 8 * scale)
                    .fill(isHovered ? Theme.hover.opacity(0.7) : .clear)
                    .padding(EdgeInsets(top: -reach, leading: -reach, bottom: descent - reach, trailing: -reach))
            )
            .frame(width: style == .capsules ? RingBarMetrics.capsuleCellWidth(scale: scale) + 2 * padding : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        // One sentence, said once ("ChatGPT 20x weekly 30% left (in use)"); a
        // separate value repeated the name.
        .accessibilityLabel(RingBarText.accessibilityLabel(for: entry, displaysRemaining: displaysRemaining))
        // `children: .ignore` drops the button's own press: VoiceOver needs it.
        .accessibilityAction { onSelect() }
        .accessibilityHint(Text("Opens Ration"))
        .accessibilityAddTraits(.isButton)
        // The hover card's facts without a hover (VoiceOver's More Content).
        .accessibilityCustomContent(
            AccessibilityCustomContentKey(Text(LocalizedStringResource.ringBarAccessibilityDetails), id: "ringBarDetails"),
            Text(verbatim: RingBarText.accessibilityDetails(
                for: RingBarText.card(for: entry, displaysRemaining: displaysRemaining, now: now)
            ).joined(separator: "; "))
        )
    }

    /// Drawn for the panel's appearance, which follows Ration's.
    private var gaugeImage: NSImage {
        StatusItemFactory.gaugeImage(
            fraction: entry.gauge.fraction,
            color: source.accentNS,
            shape: source.gaugeShape,
            inUse: style == .rail && entry.gauge.inUse,
            side: RingBarMetrics.side(style, scale: scale),
            stroke: RingBarMetrics.stroke(style, scale: scale),
            appearance: NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua) ?? NSAppearance.currentDrawing()
        )
    }
}
