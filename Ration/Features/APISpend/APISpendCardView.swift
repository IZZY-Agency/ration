import SwiftUI

/// The popover's "API" group: header + one card per unpaused org.
struct APISpendGroupView: View {
    @ObservedObject var model: APISpendModel
    var now: Date = .now

    var body: some View {
        let presentations = model.presentations(now: now)
        if !presentations.isEmpty {
            VStack(spacing: 0) {
                APISpendSectionHeader()

                ForEach(Array(presentations.enumerated()), id: \.element.id) { index, presentation in
                    APISpendCardView(presentation: presentation, thresholds: model.state.thresholds, now: now)
                    if index < presentations.count - 1 {
                        Divider().overlay(Theme.line).padding(.horizontal, AccountListMetrics.cardInset)
                    }
                }
            }
        }
    }
}

/// One API org card: dollar headline, "/ budget", day bars, budget meter, caption.
struct APISpendCardView: View {
    let presentation: APIOrgPresentation
    let thresholds: ThresholdPair
    var now: Date = .now

    private var text: APISpendCardText.Text { APISpendCardText.text(for: presentation, thresholds: thresholds, now: now) }
    private var accent: Color { presentation.org.vendor.accent }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .bottom, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(text.headline)
                        .font(Theme.display(22, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(presentation.cost == nil ? Theme.creamFaint : Theme.cream)
                    if let suffix = text.budgetSuffix {
                        Text(suffix)
                            .font(Theme.display(15, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Theme.creamFaint)
                    }
                }
                Spacer(minLength: 8)
                if let days = presentation.cost?.days, days.count >= 2, !presentation.isOldMonth {
                    APISpendDayBars(days: days, today: UTCDay.start(of: presentation.cost?.fetchedAt ?? now))
                }
            }
            if let fraction = text.meterFraction {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.track)
                        Capsule().fill(meterColor).frame(width: max(2, geometry.size.width * fraction))
                    }
                }
                .frame(height: 4)
            }
            if !text.caption.isEmpty {
                Text(text.caption)
                    .font(Theme.mono(14, bold: true))
                    .monospacedDigit()
                    .foregroundStyle(Theme.resetAccent)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, AccountListMetrics.cardInset)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(APISpendCardText.accessibilityDescription(for: presentation, thresholds: thresholds, now: now))
    }

    private var meterColor: Color {
        switch text.meterTier {
        case .critical?: Theme.crit
        case .warning?: Theme.warn
        case nil: Theme.calm
        }
    }

    private var header: some View {
        HStack(spacing: 7) {
            Circle().fill(accent).frame(width: 6, height: 6).accessibilityHidden(true)
            Text(presentation.org.label)
                .font(Theme.display(17, .semibold))
                .foregroundStyle(Theme.cream)
                .lineLimit(1)
            Text(verbatim: presentation.org.vendor.displayName.uppercased())
                .font(Theme.mono(11))
                .tracking(0.8)
                .foregroundStyle(accent)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(accent.opacity(AccountCardView.providerChipBorderOpacity), lineWidth: 1))
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            if let error = presentation.costError {
                Text(APISpendStateCopy.text(for: error))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.crit)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else if presentation.isStale {
                Text(LocalizedStringResource.badgeStale)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.warn)
            }
            if let fetched = presentation.cost?.fetchedAt {
                Text(LocalizedStringResource.apiSpendCardAsOf(fetched.formatted(date: .omitted, time: .shortened)))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.creamFaint)
                    .lineLimit(1)
            }
        }
    }
}

/// This month's spend per UTC day, today's bar highlighted.
struct APISpendDayBars: View {
    let days: [DayCost]
    let today: Date

    var body: some View {
        let peak = days.map { NSDecimalNumber(decimal: $0.cents).doubleValue }.max() ?? 0
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(days, id: \.dayStart) { day in
                let value = NSDecimalNumber(decimal: day.cents).doubleValue
                RoundedRectangle(cornerRadius: 1)
                    .fill(day.dayStart == today ? Theme.creamDim : Theme.line2)
                    .frame(width: 3, height: peak > 0 ? max(2, 24 * value / peak) : 2)
            }
        }
        .frame(height: 24, alignment: .bottom)
        .accessibilityHidden(true)
    }
}

/// The popover's "API" section header, like the provider headers.
struct APISpendSectionHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Text(LocalizedStringResource.apiSpendGroupTitle)
                .font(Theme.mono(11))
                .tracking(1.4)
                .foregroundStyle(Theme.creamFaint)
            Rectangle().fill(Theme.line).frame(height: 1)
        }
        .padding(.horizontal, AccountListMetrics.cardInset)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(LocalizedStringResource.apiSpendGroupTitle))
        .accessibilityAddTraits(.isHeader)
    }
}
