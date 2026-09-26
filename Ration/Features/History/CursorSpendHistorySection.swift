import Charts
import SwiftUI

/// History › Patterns: one Cursor account's spend per billing cycle — a bar per
/// cycle (every stored closed cycle plus the open one), the closed cycles'
/// average as a dashed rule, and a table of cycle, spend and "vs avg". The
/// open cycle is marked "so far". Cursor stays out of the Billing-cycle mode:
/// it reports its own cycle, nothing needs reconstructing.
struct CursorSpendHistorySection: View {
    let label: String
    let history: CursorSpendHistory
    let current: CursorSpend?

    private var trend: CursorSpendTrend {
        CursorSpendTrend.history(closed: history.cycles, current: current)
    }

    var body: some View {
        let trend = self.trend
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(CursorSpendHistoryCopy.sectionTitle(label: label))
                    .font(Theme.display(15, .semibold))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(CursorSpendHistoryCopy.sectionSubtitle())
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.creamDim)
                    .lineLimit(1)
            }

            if trend.bars.isEmpty {
                note(CursorSpendHistoryCopy.noData())
            } else {
                chart(trend)
                if trend.isAllZero {
                    note(CursorSpendHistoryCopy.noCharges())
                }
                if !trend.bars.contains(where: { !$0.isCurrent }) {
                    note(CursorSpendHistoryCopy.pastCyclesNote(complete: Self.isComplete(history: history, current: current)))
                }
                table(trend)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.panel)
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Theme.line, lineWidth: 1)
                )
        )
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(11))
            .foregroundStyle(Theme.creamDim)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Bars keyed by position, not by month name: thirteen cycles can repeat a
    /// month ("Sep" last year and "Sep (now)"), and a categorical axis would
    /// merge them.
    private func chart(_ trend: CursorSpendTrend) -> some View {
        let labels: [String] = trend.bars.map { CursorSpendHistoryCopy.barLabel($0) }
        var averageDollars: Double?
        if let average = trend.averageCents, average > 0 {
            averageDollars = average / 100
        }
        let averageLabel: String? = CursorSpendHistoryCopy.averageLabel(trend)
        let top: Double = Self.axisTop(trend)
        return Chart {
            ForEach(Array(trend.bars.enumerated()), id: \.offset) { index, bar in
                BarMark(
                    x: .value("Cycle", String(index)),
                    y: .value("Spend", Self.drawnDollars(bar.spentCents, axisTop: top))
                )
                .foregroundStyle(bar.isCurrent ? Theme.iris : Theme.line2)
                .cornerRadius(3)
                .accessibilityLabel(labels[index])
                .accessibilityValue(UsageFormatters.usd(cents: bar.spentCents))
            }
            if let averageDollars {
                RuleMark(y: .value("Average", averageDollars))
                    .foregroundStyle(Theme.creamDim)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .annotation(position: .top, alignment: .leading) {
                        if let averageLabel {
                            Text(averageLabel)
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.creamDim)
                        }
                    }
            }
        }
        .chartXAxis {
            AxisMarks { value in
                AxisValueLabel {
                    if let key = value.as(String.self), let index = Int(key), labels.indices.contains(index) {
                        // Thirteen bars leave ~45 pt a column: "Sep (now)"
                        // wraps onto two lines rather than running into August.
                        Text(labels[index])
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.creamDim)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(width: Self.axisLabelWidth)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks { value in
                AxisGridLine().foregroundStyle(Theme.line)
                AxisValueLabel {
                    if let dollars = value.as(Double.self) {
                        Text(UsageFormatters.usd(cents: Int((dollars * 100).rounded())))
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.creamDim)
                    }
                }
            }
        }
        .chartYScale(domain: 0...top)
        .frame(height: 150)
        .accessibilityLabel(CursorSpendHistoryCopy.sectionSubtitle())
    }

    static let axisLabelWidth: CGFloat = 52

    /// Every month of the kept window is settled — stored, or proven empty.
    /// Derived from what is owed, never from `syncedThrough`: a walk that
    /// stopped at its page cap settled nothing and must not read as "no
    /// earlier cycles".
    static func isComplete(history: CursorSpendHistory, current: CursorSpend?) -> Bool {
        guard let start = current?.periodStart else { return false }
        return CursorSpendHistoryPlanner.owedMonths(history: history, currentPeriodStart: start).isEmpty
    }

    /// The y axis top in dollars: a little above the tallest bar or the
    /// average, and at least $1 so an all-$0 account still has an axis.
    static func axisTop(_ trend: CursorSpendTrend) -> Double {
        max(trend.scaleCents / 100 * 1.1, 1)
    }

    /// A $0 cycle is drawn as a thin stub on the baseline (as on the card), so
    /// "no charges" reads as a bar at zero rather than a missing cycle. The
    /// spoken value and the table keep the real amount.
    static func drawnDollars(_ cents: Int, axisTop: Double) -> Double {
        max(Double(cents) / 100, axisTop * 0.012)
    }

    /// Newest first, the open cycle on top.
    private func table(_ trend: CursorSpendTrend) -> some View {
        let titles = CursorSpendHistoryCopy.columnTitles()
        let rows: [CursorSpendTrend.Bar] = trend.bars.reversed()
        return Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow {
                Text(titles.cycle)
                Text(titles.spend).gridColumnAlignment(.trailing)
                Text(titles.versusAverage).gridColumnAlignment(.trailing)
            }
            .font(Theme.mono(11))
            .foregroundStyle(Theme.creamFaint)

            ForEach(rows) { bar in
                GridRow {
                    Text(CursorSpendHistoryCopy.rowRange(bar))
                    Text(UsageFormatters.usd(cents: bar.spentCents))
                    Text(CursorSpendHistoryCopy.rowVersusAverage(bar, trend: trend))
                        .foregroundStyle(isAbove(bar, trend) ? Theme.warn : Theme.cream)
                }
                .font(Theme.mono(12))
                .monospacedDigit()
                .foregroundStyle(Theme.cream)
            }
        }
    }

    private func isAbove(_ bar: CursorSpendTrend.Bar, _ trend: CursorSpendTrend) -> Bool {
        guard let delta = trend.percentVersusAverage(bar.spentCents) else { return false }
        return delta > 0
    }
}
