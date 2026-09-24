import SwiftUI

/// The Ration ring mark without its tile: a track circle, a gold arc 68 %
/// clockwise from 12 o'clock with round caps, and a cream hub — the app
/// icon's recipe (scripts/generate-app-icon.swift, web/public/favicon.svg)
/// drawn in theme tokens so it follows the appearance. Decorative: the
/// wordmark beside it carries the name for VoiceOver.
struct RationMark: View {
    let size: CGFloat

    static let arcFraction: Double = 0.68

    /// Proportions of the tile-less mark (ring fills more of the box than
    /// on the tiled icon).
    struct Geometry: Equatable {
        let ringRadius: CGFloat
        let stroke: CGFloat
        let hubRadius: CGFloat

        init(size: CGFloat) {
            ringRadius = size * 0.375
            stroke = size * 0.1375
            hubRadius = size * 0.0875
        }
    }

    var body: some View {
        let g = Geometry(size: size)
        let diameter: CGFloat = g.ringRadius * 2
        ZStack {
            Circle()
                .stroke(Theme.track, lineWidth: g.stroke)
                .frame(width: diameter, height: diameter)
            Circle()
                .trim(from: 0, to: Self.arcFraction)
                .stroke(Theme.gold, style: StrokeStyle(lineWidth: g.stroke, lineCap: .round))
                // `trim` starts at 3 o'clock and runs clockwise on screen;
                // turn it back a quarter so it starts at 12.
                .rotationEffect(.degrees(-90))
                .frame(width: diameter, height: diameter)
            Circle()
                .fill(Theme.cream)
                .frame(width: g.hubRadius * 2, height: g.hubRadius * 2)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
