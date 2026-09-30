import Charts
import SwiftUI

/// Plan value on a Claude card: dollars at API list prices for the period
/// chosen in Settings.
struct TokenBurnCardLine: Equatable {
    let text: String
    let hasUse: Bool

    static func make(_ values: TokenBurnAccountValues?, trackingSince: Date?, grantLost: Bool = false,
                     locale: Locale = .current) -> TokenBurnCardLine? {
        // A lost grant is said on the card too: its figure stopped moving.
        if grantLost {
            return TokenBurnCardLine(text: LocalizedStringResource.tokenBurnCardGrantLost.string(in: locale), hasUse: false)
        }
        guard let current = values?.current else { return nil }
        return TokenBurnCardLine(text: TokenBurnCopy.cardLine(current, trackingSince: trackingSince, locale: locale),
                                 hasUse: current.value.replies > 0)
    }
}

/// The popover's line under the Claude header: all Claude Code use in the
/// period, whichever account it was (exact without tracking).
struct TokenBurnTotalLineView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Theme.mono(12))
            .monospacedDigit()
            .foregroundStyle(Theme.creamDim)
            .lineLimit(1)
            .padding(.horizontal, AccountListMetrics.cardInset)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("planValueTotalLine")
    }
}

struct TokenBurnCardLineView: View {
    let line: TokenBurnCardLine

    var body: some View {
        Text(line.text)
            .font(Theme.mono(12))
            .monospacedDigit()
            .foregroundStyle(line.hasUse ? Theme.cream : Theme.creamFaint)
            .lineLimit(1)
            .accessibilityIdentifier("planValueLine")
    }
}

/// Settings › a Claude account › Plan Value: the period, this period's
/// figure against the plan, the three before it, by model, tokens, what is on
/// no account, and what the figure is.
struct TokenBurnPlanValueSection: View {
    @ObservedObject var model: TokenBurnModel
    let accountID: UUID
    /// "Max 20x"; nil when the plan is not known.
    let planName: String?

    var body: some View {
        if model.isEnabled {
            Section(SettingsSectionTitle.planValue) {
                Picker(selection: Binding(
                    get: { model.period },
                    set: { choice in Task { await model.setPeriod(choice) } }
                )) {
                    ForEach(TokenBurnPeriod.Choice.allCases, id: \.self) { choice in
                        Text(TokenBurnCopy.choice(choice)).tag(choice)
                    }
                } label: {
                    Text(LocalizedStringResource.tokenBurnPeriodLabel)
                }
                .accessibilityIdentifier("planValuePeriodPicker")
                note(LocalizedStringResource.tokenBurnPeriodNote)

                if let values = model.values[accountID] {
                    headline(values)
                    note(verbatim: TokenBurnCopy.perAccountNote(trackingSince: model.trackingSince))
                    if let total = model.total {
                        LabeledContent {
                            Text(amount(total)).monospacedDigit()
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(LocalizedStringResource.tokenBurnTotalLabel)
                                Text(TokenBurnCopy.choice(model.period)).font(Theme.mono(12)).foregroundStyle(Theme.creamDim)
                            }
                        }
                        .accessibilityIdentifier("planValueTotal")
                    }
                    earlier(values)
                    byModel(values)
                    tokens(values.tokens)
                    pooled
                    footnotes(values)
                } else {
                    note(LocalizedStringResource.tokenBurnHistoryEmpty)
                }
            }
        }
    }

    private func note(_ text: LocalizedStringResource) -> some View {
        Text(text).font(Theme.mono(12)).foregroundStyle(Theme.creamDim)
    }

    private func note(verbatim text: String) -> some View {
        Text(verbatim: text).font(Theme.mono(12)).foregroundStyle(Theme.creamDim)
    }

    private func subheading(_ text: LocalizedStringResource) -> some View {
        Text(text).font(Theme.display(13, .semibold)).foregroundStyle(Theme.creamDim).padding(.top, 4)
    }

    private func amount(_ value: PlanValue) -> String {
        TokenBurnCopy.amount(cents: value.cents, atLeast: !value.isComplete)
    }

    private func headline(_ values: TokenBurnAccountValues) -> some View {
        let current = values.current
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(TokenBurnCopy.title(current.period.kind))
                    Text(TokenBurnCopy.range(current.period)).font(Theme.mono(12)).foregroundStyle(Theme.creamDim)
                }
                Spacer()
                Text(amount(current.value))
                    .font(Theme.mono(20, bold: true))
                    .monospacedDigit()
                    .foregroundStyle(Theme.cream)
            }
            let partial = TokenBurnCopy.isPartial(current.period, trackingSince: model.trackingSince)
            if let tracking = model.trackingSince, partial {
                // Per account, only the time since Ration started tracking.
                Text(LocalizedStringResource.tokenBurnSince(TokenBurnCopy.moment(tracking), current.value.replies))
                    .font(Theme.mono(12)).foregroundStyle(Theme.creamDim)
            } else if model.trackingSince != nil {
                Text(LocalizedStringResource.tokenBurnReplies(current.value.replies))
                    .font(Theme.mono(12)).foregroundStyle(Theme.creamDim)
            }
            if values.since == nil {
                note(LocalizedStringResource.tokenBurnNoUse)
            }
            // Against the monthly price only when the whole period is known.
            if !partial, let ratio = current.ratio, let planName, let price = current.planPriceUSD {
                let priceText = UsageFormatters.usd(cents: Int(NSDecimalNumber(decimal: price * 100).intValue), alertStyle: true)
                Text(LocalizedStringResource.tokenBurnRatio(TokenBurnCopy.ratio(ratio), planName, priceText))
                    .font(Theme.mono(12)).foregroundStyle(Theme.creamDim)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("planValueHeadline")
    }

    @ViewBuilder
    private func earlier(_ values: TokenBurnAccountValues) -> some View {
        subheading(LocalizedStringResource.tokenBurnEarlier)
        ForEach(Array(values.previous.enumerated()), id: \.offset) { _, earlier in
            LabeledContent {
                if earlier.value.replies == 0, values.since.map({ earlier.period.end <= $0 }) ?? true {
                    Text(LocalizedStringResource.tokenBurnBeforeTracking).foregroundStyle(Theme.creamFaint)
                } else {
                    Text(amount(earlier.value)).monospacedDigit()
                }
            } label: {
                Text(TokenBurnCopy.range(earlier.period))
            }
        }
    }

    @ViewBuilder
    private func byModel(_ values: TokenBurnAccountValues) -> some View {
        if !values.byModel.isEmpty {
            subheading(LocalizedStringResource.tokenBurnByModel)
            ForEach(values.byModel, id: \.model) { entry in
                LabeledContent {
                    Text(amount(entry.value)).monospacedDigit()
                } label: {
                    Text(verbatim: TokenBurnCopy.modelName(entry.model))
                }
            }
        }
    }

    @ViewBuilder
    private func tokens(_ tokens: TokenCounts) -> some View {
        if tokens.total > 0 {
            subheading(LocalizedStringResource.tokenBurnTokens)
            LabeledContent { Text(TokenBurnCopy.tokens(tokens.cacheRead)) } label: {
                Text(LocalizedStringResource.tokenBurnTokensCacheRead)
            }
            LabeledContent {
                Text(TokenBurnCopy.tokens(tokens.cacheWrite5m + tokens.cacheWrite1h + tokens.cacheWriteUnsplit))
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringResource.tokenBurnTokensCacheWrite)
                    Text(LocalizedStringResource.tokenBurnTokensCacheSplit(TokenBurnCopy.tokens(tokens.cacheWrite5m),
                                                                          TokenBurnCopy.tokens(tokens.cacheWrite1h)))
                        .font(Theme.mono(12)).foregroundStyle(Theme.creamDim)
                }
            }
            LabeledContent { Text(TokenBurnCopy.tokens(tokens.output)) } label: {
                Text(LocalizedStringResource.tokenBurnTokensOutput)
            }
            LabeledContent { Text(TokenBurnCopy.tokens(tokens.input)) } label: {
                Text(LocalizedStringResource.tokenBurnTokensInput)
            }
        }
    }

    @ViewBuilder
    private var pooled: some View {
        let owners = TokenBurnFigures.pooledOwners.filter { model.pooled[$0] != nil }
        if !owners.isEmpty {
            subheading(LocalizedStringResource.tokenBurnPooled)
            ForEach(owners, id: \.self) { owner in
                LabeledContent {
                    Text(amount(model.pooled[owner] ?? PlanValue())).monospacedDigit()
                } label: {
                    Text(verbatim: TokenBurnCopy.owner(owner) ?? "")
                }
            }
        }
    }

    private func footnotes(_ values: TokenBurnAccountValues) -> some View {
        let value = values.current.value
        let listed = ClaudePriceTable.listedOn.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted))
        let share = value.pricedTokens + value.unpricedTokens > 0
            ? Double(value.assumedTokens + value.unpricedTokens) / Double(value.pricedTokens + value.unpricedTokens) : 0
        return VStack(alignment: .leading, spacing: 6) {
            note(LocalizedStringResource.tokenBurnNoteEstimate(listed))
            if !value.isComplete {
                note(LocalizedStringResource.tokenBurnNoteAtLeast(
                    UsageFormatters.wholePercent(max(1, Int((share * 100).rounded())), monospaced: true)))
            }
            if let countedThrough = model.countedThrough {
                note(LocalizedStringResource.tokenBurnCountedThrough(TokenBurnCopy.moment(countedThrough)))
            }
            note(LocalizedStringResource.tokenBurnNoteLimits)
        }
    }
}

/// History › Plan value: dollars per day at API list prices for the chosen
/// period, one colour per Claude account (the History ladder), use on no
/// account in grey.
struct TokenBurnHistoryView: View {
    @ObservedObject var model: TokenBurnModel
    /// The Claude accounts, in card order.
    let accounts: [AccountRecord]

    private struct Series: Identifiable {
        let id: String
        let name: String
        let color: Color
        let owners: Set<TokenBurnOwner>
        let total: PlanValue
    }

    private struct Bar: Identifiable {
        let id: String
        let day: Date
        let series: String
        let dollars: Double
    }

    private var series: [Series] {
        func total(_ owners: Set<TokenBurnOwner>) -> PlanValue {
            var total = PlanValue()
            for day in model.days {
                for owner in owners {
                    guard let value = day.values[owner] else { continue }
                    total.cents += value.cents
                    total.replies += value.replies
                    total.pricedTokens += value.pricedTokens
                    total.unpricedTokens += value.unpricedTokens
                    total.assumedTokens += value.assumedTokens
                }
            }
            return total
        }
        var result = accounts.enumerated().map { index, account in
            let owners: Set<TokenBurnOwner> = [.account(account.id)]
            return Series(id: account.id.uuidString, name: account.historyLabel,
                          color: HistoryOverlayPalette.color(provider: .claude, shadeIndex: index), owners: owners,
                          total: total(owners))
        }
        let before: Set<TokenBurnOwner> = [.beforeTracking]
        result.append(Series(id: "before", name: TokenBurnCopy.owner(.beforeTracking) ?? "", color: Theme.line2,
                             owners: before, total: total(before)))
        let other: Set<TokenBurnOwner> = [.notObserved, .unassigned, .apiKey, .unclassified]
        result.append(Series(id: "other", name: LocalizedStringResource.tokenBurnPooled.string(in: .current),
                             color: Theme.creamFaint, owners: other, total: total(other)))
        return result.filter { $0.total.replies > 0 }
    }

    private func bars(_ series: [Series]) -> [Bar] {
        model.days.flatMap { day in
            series.map { entry in
                let cents = entry.owners.reduce(Decimal(0)) { $0 + (day.values[$1]?.cents ?? 0) }
                return Bar(id: "\(entry.id)-\(day.day.timeIntervalSince1970)", day: day.day, series: entry.name,
                           dollars: NSDecimalNumber(decimal: cents / 100).doubleValue)
            }
        }
    }

    /// Every fifth day back from today (every day for a week), at midday.
    private var labelledDays: [Date] {
        let step = model.days.count > 10 ? 5 : 1
        return model.days.reversed().enumerated().filter { $0.offset % step == 0 }
            .map { $0.element.day.addingTimeInterval(12 * 3_600) }
    }

    var body: some View {
        let series = series
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(LocalizedStringResource.tokenBurnHistoryTitle(TokenBurnCopy.choice(model.period)))
                        .font(Theme.display(17, .semibold))
                        .foregroundStyle(Theme.cream)
                    Spacer()
                    Text(LocalizedStringResource.tokenBurnHistorySubtitle)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)
                }
                if series.isEmpty {
                    Text(LocalizedStringResource.tokenBurnHistoryEmpty)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)
                } else {
                    Chart(bars(series)) { bar in
                        BarMark(x: .value("Day", bar.day, unit: .day), y: .value("Dollars", bar.dollars))
                            .foregroundStyle(by: .value("Series", bar.series))
                    }
                    .chartForegroundStyleScale(domain: series.map(\.name), range: series.map(\.color))
                    .chartLegend(.hidden)
                    .chartYAxis {
                        AxisMarks { value in
                            AxisGridLine().foregroundStyle(Theme.line)
                            AxisValueLabel {
                                if let dollars = value.as(Double.self) {
                                    Text(UsageFormatters.usd(cents: Int((dollars * 100).rounded()), alertStyle: true))
                                        .font(Theme.mono(10))
                                        .foregroundStyle(Theme.creamFaint)
                                }
                            }
                        }
                    }
                    .chartXAxis {
                        // At each labelled day's midday, under its bar (a day's
                        // bar spans the day; `centered` would centre a label on
                        // the whole stride instead).
                        AxisMarks(values: labelledDays) { _ in
                            AxisValueLabel(format: .dateTime.day())
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.creamFaint)
                        }
                    }
                    .frame(height: 260)
                    .accessibilityIdentifier("planValueChart")

                    VStack(alignment: .leading, spacing: 6) {
                        if let total = model.total {
                            HStack(spacing: 8) {
                                Text(LocalizedStringResource.tokenBurnTotalLabel)
                                Spacer()
                                Text(TokenBurnCopy.amount(cents: total.cents, atLeast: !total.isComplete)).monospacedDigit()
                            }
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.cream)
                        }
                        ForEach(series) { entry in
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 2).fill(entry.color).frame(width: 10, height: 10)
                                Text(verbatim: entry.name)
                                Spacer()
                                Text(TokenBurnCopy.amount(cents: entry.total.cents, atLeast: !entry.total.isComplete))
                                    .monospacedDigit()
                            }
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.creamDim)
                        }
                    }
                    Text(verbatim: TokenBurnCopy.perAccountNote(trackingSince: model.trackingSince))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.creamFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(16)
        }
    }
}
