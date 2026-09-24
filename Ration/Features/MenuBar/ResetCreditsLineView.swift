import SwiftUI

struct ResetCreditsLineView: View {
    let summary: ResetCreditsSummary
    let now: Date

    var body: some View {
        Text(summary.text(now: now))
            .font(Theme.mono(12))
            .monospacedDigit()
            .foregroundStyle(summary.noneUsable ? Theme.creamFaint : (summary.withinLeadWindow ? Theme.warn : Theme.resetAccent))
            .lineLimit(1)
            .accessibilityLabel(summary.accessibilityText(now: now))
    }
}
