import SwiftUI

/// A 24-cell hour-of-day row: each cell's fill intensity encodes that hour's
/// `averageConsumed` relative to the busiest hour in the set, so the row
/// reads as a burn-rate "heat" pattern across the capture-local day.
struct HistoryHeatmapView: View {
    let hours: [HourOfDayBurn]

    private var sortedHours: [HourOfDayBurn] {
        hours.sorted { $0.hour < $1.hour }
    }

    private var maxConsumed: Double {
        hours.map(\.averageConsumed).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Hour of Day")
                .font(Theme.mono(10, bold: true))
                .tracking(1.0)
                .textCase(.uppercase)
                .foregroundStyle(Theme.creamFaint)

            HStack(spacing: 3) {
                ForEach(sortedHours, id: \.hour) { hour in
                    cell(for: hour)
                }
            }

            HStack(spacing: 3) {
                ForEach(sortedHours, id: \.hour) { hour in
                    tick(for: hour)
                }
            }
        }
    }

    private func cell(for hour: HourOfDayBurn) -> some View {
        let fraction = normalizedFraction(hour.averageConsumed)
        return RoundedRectangle(cornerRadius: 3)
            .fill(fraction > 0 ? Theme.resetAccent.opacity(0.12 + fraction * 0.72) : Theme.panel)
            .overlay(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Theme.line, lineWidth: 1)
            )
            .frame(height: 26)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel(for: hour))
    }

    private func tick(for hour: HourOfDayBurn) -> some View {
        Group {
            if hour.hour % 6 == 0 {
                Text("\(hour.hour)")
                    .font(Theme.mono(8))
                    .foregroundStyle(Theme.creamFaint)
                    .frame(maxWidth: .infinity)
            } else {
                Color.clear.frame(maxWidth: .infinity, maxHeight: 1)
            }
        }
        .accessibilityHidden(true)
    }

    private func normalizedFraction(_ consumed: Double) -> Double {
        guard maxConsumed > 0 else { return 0 }
        return min(max(consumed / maxConsumed, 0), 1)
    }

    private func accessibilityLabel(for hour: HourOfDayBurn) -> String {
        let hourLabel = String(format: "%02d:00", hour.hour)
        let percent = UsageFormatters.usedPercentage(hour.averageConsumed)
        return "\(hourLabel), \(percent) average burn"
    }
}
