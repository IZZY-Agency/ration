import SwiftUI

/// A single usage window rendered as one inline row: mono label · hairline
/// meter · percentage. Compact "Terminal Ledger" treatment.
struct LimitRowView: View {
    let title: String
    let window: UsageWindow?
    var now: Date = .now

    private var tint: Color {
        guard let window else { return Theme.creamFaint }
        return Theme.tierColor(usedFraction: window.usedFraction)
    }

    private var numberColor: Color {
        guard let window else { return Theme.creamFaint }
        return window.usedFraction >= 0.50 ? tint : Theme.cream
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Text(title)
                    .font(Theme.mono(11))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.creamFaint)

                if let window {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.cream.opacity(0.09))
                            Capsule()
                                .fill(tint)
                                .frame(
                                    width: max(2, geometry.size.width * window.usedFraction)
                                )
                        }
                    }
                    .frame(height: 4)

                    Text(UsageFormatters.usedPercentage(window.usedFraction))
                        .font(Theme.mono(13.5))
                        .monospacedDigit()
                        .foregroundStyle(numberColor)
                        .contentTransition(.numericText())
                        // Never let the "NN %" break onto a second line — the
                        // meter (GeometryReader) flexes to give this its natural
                        // width instead.
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                } else {
                    Rectangle().fill(Theme.cream.opacity(0.06))
                        .frame(height: 4).clipShape(Capsule())
                    Text("—")
                        .font(Theme.mono(13.5))
                        .foregroundStyle(Theme.creamFaint)
                }
            }

            resetCaption
        }
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    @ViewBuilder
    private var resetCaption: some View {
        HStack(spacing: 4) {
            if let resetsAt = window?.resetsAt {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 9.5, weight: .bold))
                Text(UsageFormatters.remainingUntilReset(resetsAt, relativeTo: now))
                    .font(Theme.mono(12, bold: true))
                    .monospacedDigit()
                    .lineLimit(1)
            } else if window != nil {
                Text("no scheduled reset")
                    .font(Theme.mono(9.5))
                    .lineLimit(1)
                    .foregroundStyle(Theme.creamFaint)
            }
        }
        .foregroundStyle(Theme.resetAccent)
        .accessibilityHidden(true)
    }

    private var tooltip: String {
        guard let window else { return "\(title): unavailable" }
        guard let resetsAt = window.resetsAt else { return "\(title): no scheduled reset" }
        return "\(title) · resets \(UsageFormatters.compactReset(resetsAt, relativeTo: now))"
    }

    private var accessibilityDescription: String {
        guard let window else { return "\(title), unavailable" }
        let reset = window.resetsAt.map {
            "resets \(UsageFormatters.compactReset($0, relativeTo: now))"
        } ?? "reset not scheduled"
        return "\(title), \(UsageFormatters.usedPercentage(window.usedFraction)) used, \(reset)"
    }
}
