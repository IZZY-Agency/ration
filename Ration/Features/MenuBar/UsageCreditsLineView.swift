import SwiftUI

/// "Credits €10.00 · off" under a Claude card's resets line.
struct UsageCreditsLineView: View {
    let summary: UsageCreditsSummary
    let now: Date

    var body: some View {
        Text(summary.text(now: now))
            .font(Theme.mono(12))
            .monospacedDigit()
            .foregroundStyle(summary.isOld ? Theme.creamFaint : (summary.expiring != nil ? Theme.warn : Theme.creamDim))
            .lineLimit(1)
            .accessibilityLabel(summary.accessibilityText(now: now))
    }
}

/// "Credits 120" under a ChatGPT card's resets line.
struct CodexCreditsLineView: View {
    let credits: CodexCredits

    var body: some View {
        Text(CodexCreditsCopy.line(credits))
            .font(Theme.mono(12))
            .monospacedDigit()
            .foregroundStyle(Theme.creamDim)
            .lineLimit(1)
            .accessibilityLabel(CodexCreditsCopy.spoken(credits))
    }
}
