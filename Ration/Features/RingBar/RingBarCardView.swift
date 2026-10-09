import SwiftUI

/// The ring bar's hover card: opaque, never glass, so glass never sits on
/// glass (Apple's Liquid Glass guidance).
struct RingBarCardView: View {
    let card: RingBarCard

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(verbatim: card.provider.uppercased())
                .font(Theme.mono(9.5, bold: true))
                .foregroundStyle(card.source.accent)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(verbatim: card.title)
                    .font(Theme.display(14.5, .semibold))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                if card.inUse {
                    Text(LocalizedStringResource.inUsePill)
                        .font(Theme.mono(9, bold: true))
                        .foregroundStyle(Theme.active)
                }
            }
            ForEach(Array(card.lines.enumerated()), id: \.offset) { _, line in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(verbatim: line.text)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.cream)
                        if line.isStale {
                            Text(LocalizedStringResource.badgeStale)
                                .font(Theme.mono(10, bold: true))
                                .foregroundStyle(Theme.warn)
                        }
                    }
                    if let detail = line.detail {
                        Text(verbatim: detail)
                            .font(Theme.mono(11.5))
                            .foregroundStyle(Theme.resetAccent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: RingBarMetrics.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line2, lineWidth: 1))
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
