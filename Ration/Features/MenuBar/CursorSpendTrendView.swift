import SwiftUI

/// Every string the Cursor spend history draws, built in code so each
/// language is pinned by tests. Amounts go through `UsageFormatters.usd`
/// (`currency.usd`), percentages through `UsageFormatters.wholePercent` in its
/// monospaced form (U+00A0 before "%" in French).
enum CursorSpendHistoryCopy {
    /// "+38%", "−19%" (U+2212), "0%".
    static func signedPercent(_ value: Int, locale: Locale = .current) -> String {
        let magnitude: String = UsageFormatters.wholePercent(abs(value), monospaced: true, locale: locale)
        if value > 0 { return "+" + magnitude }
        if value < 0 { return "\u{2212}" + magnitude }
        return magnitude
    }

    /// The line under the Cursor card: "+38% vs your 6-cycle average ($29.80)",
    /// or — when every averaged cycle was $0 — "no usage-based charges in your
    /// last 6 cycles". nil below two closed cycles, or without an open cycle
    /// to compare.
    static func cardLine(_ trend: CursorSpendTrend, locale: Locale = .current) -> String? {
        guard let average = trend.averageCents, let rounded = trend.roundedAverageCents else { return nil }
        if average == 0 {
            return LocalizedStringResource.cursorHistoryCardNoCharges(cycles: trend.averagedCycles).string(in: locale)
        }
        guard let delta = trend.currentVersusAverage else { return nil }
        let percent: String = signedPercent(delta, locale: locale)
        let amount: String = UsageFormatters.usd(cents: rounded, locale: locale)
        return LocalizedStringResource.cursorHistoryVsAverage(percent, cycles: trend.averagedCycles, amount).string(in: locale)
    }

    /// "Cursor · Team".
    static func sectionTitle(label: String, locale: Locale = .current) -> String {
        LocalizedStringResource.cursorHistorySectionTitle(label).string(in: locale)
    }

    static func sectionSubtitle(locale: Locale = .current) -> String {
        LocalizedStringResource.cursorHistorySectionSubtitle.string(in: locale)
    }

    /// The chart's average rule: "avg $29.80".
    static func averageLabel(_ trend: CursorSpendTrend, locale: Locale = .current) -> String? {
        guard let rounded = trend.roundedAverageCents else { return nil }
        let amount: String = UsageFormatters.usd(cents: rounded, locale: locale)
        return LocalizedStringResource.cursorHistoryAverage(amount).string(in: locale)
    }

    /// A bar's axis label: "Aug", or "Sep (now)" for the open cycle.
    static func barLabel(_ bar: CursorSpendTrend.Bar, locale: Locale = .current) -> String {
        let month: String = bar.periodStart.formatted(dateStyle(locale: locale).month(.abbreviated))
        guard bar.isCurrent else { return month }
        return LocalizedStringResource.cursorHistoryBarCurrent(month).string(in: locale)
    }

    /// A table row's cycle: "Aug 1 – Sep 1", or "Since Sep 1 (so far)" for the
    /// open cycle, whose reported end is only the fetch time.
    static func rowRange(_ bar: CursorSpendTrend.Bar, locale: Locale = .current) -> String {
        let style = dateStyle(locale: locale).month(.abbreviated).day()
        let start: String = bar.periodStart.formatted(style)
        guard let end = bar.periodEnd, !bar.isCurrent else {
            return LocalizedStringResource.cursorHistoryRowCurrent(start).string(in: locale)
        }
        return LocalizedStringResource.cursorHistoryRowRange(start, end.formatted(style)).string(in: locale)
    }

    /// A row's "vs avg" cell, or "—" without a usable average.
    static func rowVersusAverage(_ bar: CursorSpendTrend.Bar, trend: CursorSpendTrend, locale: Locale = .current) -> String {
        guard let delta = trend.percentVersusAverage(bar.spentCents) else { return "—" }
        return signedPercent(delta, locale: locale)
    }

    /// The History note for an account with no usage-based charges at all.
    static func noCharges(locale: Locale = .current) -> String {
        LocalizedStringResource.cursorHistoryNoCharges.string(in: locale)
    }

    /// No past cycle is stored yet: the read is still owed, or it found none.
    static func pastCyclesNote(complete: Bool, locale: Locale = .current) -> String {
        let resource: LocalizedStringResource = complete ? .cursorHistoryNoEarlierCycles : .cursorHistoryPending
        return resource.string(in: locale)
    }

    static func noData(locale: Locale = .current) -> String {
        LocalizedStringResource.cursorHistoryNoData.string(in: locale)
    }

    static func columnTitles(locale: Locale = .current) -> (cycle: String, spend: String, versusAverage: String) {
        let cycle: String = LocalizedStringResource.cursorHistoryColumnCycle.string(in: locale)
        let spend: String = LocalizedStringResource.cursorHistoryColumnSpend.string(in: locale)
        let versus: String = LocalizedStringResource.cursorHistoryColumnVersusAverage.string(in: locale)
        return (cycle, spend, versus)
    }

    /// Cycle boundaries are UTC calendar boundaries (Cursor's invoice months),
    /// so they are drawn in UTC — "Sep 1" everywhere, never "Aug 31" west of
    /// Greenwich — in the app language alone.
    private static func dateStyle(locale: Locale) -> Date.FormatStyle {
        let shipped: Locale = LocalizedCopy.shippedLocale(for: locale)
        let language: String = shipped.language.languageCode?.identifier ?? "en"
        return Date.FormatStyle(
            locale: Locale(identifier: language),
            calendar: CursorSpendHistoryPlanner.utcCalendar,
            timeZone: CursorSpendHistoryPlanner.utcCalendar.timeZone
        )
    }
}

/// The card's six small bars: one per cycle, the open one in Cursor's iris and
/// last, the average as a dashed rule. Decorative for VoiceOver — the line
/// under the card says the same in words.
struct CursorSpendMiniBars: View {
    let trend: CursorSpendTrend

    static let barWidth: CGFloat = 11
    static let spacing: CGFloat = 4
    static let height: CGFloat = 30
    /// A $0 cycle still draws, as a stub on the baseline.
    static let minimumBarHeight: CGFloat = 2

    static func width(barCount: Int) -> CGFloat {
        guard barCount > 0 else { return 0 }
        return CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
    }

    static func barHeight(cents: Int, scale: Double) -> CGFloat {
        guard scale > 0 else { return minimumBarHeight }
        let fraction: Double = Double(cents) / scale
        return max(minimumBarHeight, CGFloat(fraction) * height)
    }

    var body: some View {
        let scale: Double = trend.scaleCents
        let width: CGFloat = Self.width(barCount: trend.bars.count)
        ZStack(alignment: .bottomLeading) {
            HStack(alignment: .bottom, spacing: Self.spacing) {
                ForEach(trend.bars) { bar in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(bar.isCurrent ? Theme.iris : Theme.line2)
                        .frame(width: Self.barWidth, height: Self.barHeight(cents: bar.spentCents, scale: scale))
                }
            }
            if let average = trend.averageCents, scale > 0 {
                let y: CGFloat = Self.height - CGFloat(average / scale) * Self.height
                Path { path in
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: width, y: y))
                }
                .stroke(Theme.creamDim, style: StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }
        }
        .frame(width: width, height: Self.height, alignment: .bottomLeading)
        .accessibilityHidden(true)
    }
}

/// "+38% vs your 6-cycle average ($29.80)" under the Cursor card; the
/// percentage in the warning ink when the open cycle is above average.
struct CursorSpendTrendLine: View {
    let trend: CursorSpendTrend

    var body: some View {
        if let line = CursorSpendHistoryCopy.cardLine(trend) {
            Text(styled(line))
                .font(Theme.mono(12))
                .monospacedDigit()
                .foregroundStyle(Theme.creamDim)
                .lineLimit(1)
        }
    }

    private func styled(_ line: String) -> AttributedString {
        var attributed = AttributedString(line)
        guard let delta = trend.currentVersusAverage, delta > 0 else { return attributed }
        let percent: String = CursorSpendHistoryCopy.signedPercent(delta)
        if let range = attributed.range(of: percent) {
            attributed[range].foregroundColor = Theme.warn
        }
        return attributed
    }
}
