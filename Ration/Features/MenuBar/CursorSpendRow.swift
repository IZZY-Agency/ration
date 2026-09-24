import SwiftUI

/// Cursor's card content is dollars-based, not a rolling-window fraction —
/// there's no meter to fill, just "how much have I spent this cycle, and
/// when does that reset." `text(for:now:)` is the pure, tested core;
/// `CursorSpendRowView` renders it in the "Terminal Ledger" idiom shared
/// with `LimitRowView`.
enum CursorSpendRow {
    static func text(
        for spend: CursorSpend?,
        now: Date
    ) -> (headline: String, caption: String, isAvailable: Bool) {
        guard let spend else {
            return (headline: "—", caption: "", isAvailable: false)
        }
        let headline = "$" + String(format: "%.2f", spend.spentDollars)
        // A real $0.00 is the COMMON case: usage-based charges only accrue past
        // the plan's included allowance, so an account inside its allowance
        // legitimately spends nothing all cycle. Say that explicitly — a bare
        // "$0.00 · this cycle" reads like a failed read rather than a true zero.
        var parts = [spend.spentCents == 0 ? "no usage-based charges" : "this cycle"]
        // Only a reset still ahead is a countdown — see `CursorSpend.futureReset`.
        if let reset = spend.futureReset(relativeTo: now) {
            parts.append(
                "resets in " + UsageFormatters.remainingUntilReset(reset, relativeTo: now)
            )
        }
        return (headline: headline, caption: parts.joined(separator: " · "), isAvailable: true)
    }

    /// What VoiceOver reads for the row — the countdown in words ("resets in
    /// 4 days, 3 hours"), never the drawn "4d 3h".
    static func accessibilityDescription(
        for spend: CursorSpend?,
        now: Date,
        locale: Locale = .current
    ) -> String {
        guard let spend else { return "Cursor spend, unavailable" }
        let headline = text(for: spend, now: now).headline
        var parts = ["Cursor spend", headline, spend.planLabel]
        parts.append(spend.spentCents == 0 ? "no usage-based charges" : "this cycle")
        if let reset = spend.futureReset(relativeTo: now) {
            parts.append("resets in " + UsageFormatters.spokenDuration(until: reset, relativeTo: now, locale: locale))
        }
        return parts.joined(separator: ", ")
    }
}

/// The Cursor card's single content row: `$`-spend headline, a muted reset
/// caption, and — when available — the plan label as a small visible tag.
/// Presence-gated on `spend`; nil renders just the "—" unavailable headline,
/// matching the before-first-read idiom other providers use.
struct CursorSpendRowView: View {
    let spend: CursorSpend?
    var now: Date = .now

    private var text: (headline: String, caption: String, isAvailable: Bool) {
        CursorSpendRow.text(for: spend, now: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(text.headline)
                    .font(Theme.display(22, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(text.isAvailable ? Theme.cream : Theme.creamFaint)
                    .contentTransition(.numericText())

                if let planLabel = spend?.planLabel {
                    Text(planLabel)
                        .font(Theme.mono(11))
                        .tracking(0.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.creamFaint)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Theme.line2, lineWidth: 1)
                        )
                }
            }

            if !text.caption.isEmpty {
                Text(text.caption)
                    .font(Theme.mono(14, bold: true))
                    .monospacedDigit()
                    .foregroundStyle(Theme.resetAccent)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        CursorSpendRow.accessibilityDescription(for: spend, now: now)
    }
}
