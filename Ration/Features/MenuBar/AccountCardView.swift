import SwiftUI

struct AccountCardView: View {
    let presentation: AccountPresentation
    let onReauthenticate: () -> Void
    var samples: (UsageWindowKind) -> [UsageHistorySample] = { _ in [] }
    var projection: (UsageWindowKind) -> Date? = { _ in nil }
    var activeUsage: ActiveUsage? = nil
    /// The Resets feature switch (Settings → General → Features).
    var showsResetCredits: Bool = true
    var now: Date = .now
    var resetLeadDays: Int = 1
    /// Cursor only: the account's stored closed cycles, oldest first.
    var cursorHistory: [CursorSpendCycle] = []
    /// A click on a problem badge — the header's STALE click
    /// (`MenuBarView.onFreshnessAction`). nil keeps the badge plain.
    var onProblem: ((FreshnessHelp.Target) -> Void)? = nil
    /// The pointer entered / left the problem badge, or it moved.
    var onProblemHover: (BadgeHoverEvent) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme

    /// Identity accent: the provider dot and the provider chip (its text and
    /// its border). The in-use frame and pill use `Theme.active` — state and
    /// identity are separate color channels.
    private var accent: Color { Self.providerChipAccent(for: presentation.account.provider) }

    /// The provider chip's border: its accent, faint enough to frame the chip
    /// without competing with the account name.
    static let providerChipBorderOpacity = 0.16

    var body: some View {
        TimelineView(.periodic(from: now, by: 60)) { context in
            card(relativeTo: context.date)
        }
    }

    static func isHighlighted(phase: InUsePhase) -> Bool { phase != .none }

    /// "Work, Claude" — plus the plan when known: "Work, Claude Max 20x".
    static func nameAccessibilityLabel(for account: AccountRecord) -> String {
        let provider: String = account.provider.displayName
        guard let plan = account.effectivePlan else { return "\(account.label), \(provider)" }
        return "\(account.label), \(provider) \(plan.displayName)"
    }

    /// The provider chip (CLAUDE / CHATGPT / CURSOR) names the provider, so it
    /// wears that provider's identity accent — it was Claude gold for all.
    static func providerChipAccent(for provider: Provider) -> Color { provider.markAccent }

    /// Frame color for the activity highlight: the SAME `Theme.active` green
    /// as the menu-bar dot and the IN USE pill — one pattern across surfaces.
    /// Full green while in use; the last-used tail dims the same hue so
    /// intensity encodes recency without introducing a second color.
    static func highlightStroke(phase: InUsePhase, scheme: ColorScheme) -> Color {
        switch phase {
        case .inUse: Theme.active
        case .lastUsed: Theme.active.opacity(Theme.lastUsedFrameOpacity(scheme))
        case .none: .clear
        }
    }

    private func problemAction(now currentDate: Date) -> AccountBadgeProblemAction? {
        guard let onProblem else { return nil }
        return AccountStateBadge.problemAction(
            for: presentation,
            now: currentDate,
            perform: onProblem,
            hoverChanged: onProblemHover
        )
    }

    private func card(relativeTo currentDate: Date) -> some View {
        let phase = InUsePhase.classify(activeUsage, now: currentDate)
        let highlighted = Self.isHighlighted(phase: phase)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Circle()
                    .fill(accent)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)

                Text(presentation.account.label)
                    .font(Theme.display(17, .semibold))
                    .foregroundStyle(Theme.cream)
                    .lineLimit(1)
                    .accessibilityLabel(Self.nameAccessibilityLabel(for: presentation.account))

                Text(presentation.account.provider.rawValue)
                    .font(Theme.mono(11))
                    .tracking(0.8)
                    .textCase(.uppercase)
                    .foregroundStyle(accent)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(accent.opacity(Self.providerChipBorderOpacity), lineWidth: 1)
                    )
                    .accessibilityHidden(true)

                if let planTag = PlanChoice.tag(for: presentation.account) {
                    PlanTagView(tag: planTag)
                }

                Spacer(minLength: 8)
                AccountStateBadge(
                    state: presentation.state,
                    style: .compact,
                    now: currentDate,
                    onReauthenticate: onReauthenticate,
                    agedOut: AccountStateBadge.showsAgedOut(presentation, now: currentDate),
                    problemAction: problemAction(now: currentDate)
                )
            }

            InUseMarkerContent(
                phase: phase,
                date: currentDate,
                style: .full
            )

            if presentation.account.provider == .cursor {
                let spend: CursorSpend? = presentation.snapshot?.cursorSpend
                let trend = CursorSpendTrend.card(closed: cursorHistory, current: spend)
                CursorSpendRowView(spend: spend, now: currentDate, trend: trend)
                CursorSpendTrendLine(trend: trend)
            } else {
                let kinds = AccountLimitLayout.kinds(
                    for: presentation.account.provider,
                    snapshot: presentation.snapshot
                )
                HStack(alignment: .top, spacing: 14) {
                    ForEach(kinds, id: \.self) { kind in
                        let window = presentation.snapshot?.window(for: kind)
                        // Evaluate the (potentially time-dependent) suppliers once
                        // so the visibility gate and the sparkline it feeds see an
                        // identical snapshot — projection() reads `.now` and can
                        // cross the projector's freshness cutoff between calls.
                        let windowSamples = samples(kind)
                        let windowProjection = projection(kind)
                        VStack(alignment: .leading, spacing: 4) {
                            LimitRowView(
                                title: AccountLimitLayout.title(for: kind, snapshot: presentation.snapshot),
                                window: window,
                                now: currentDate,
                                kind: kind
                            )
                            // Only add the sparkline subview when there's a
                            // meaningful trend to show — a flat window's row
                            // stays exactly as tall as it was before sparklines
                            // existed, with no reserved gap or stray rule.
                            if SparklineVisibility.hasMeaningfulTrend(
                                samples: windowSamples,
                                projection: windowProjection
                            ) {
                                UsageSparkline(
                                    samples: windowSamples,
                                    projection: windowProjection,
                                    tierUsedFraction: window?.usedFraction ?? 0,
                                    now: currentDate
                                )
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }

                if showsResetCredits, let summary = ResetCreditsSummary.make(
                    credits: presentation.snapshot?.resetCredits,
                    leadDays: resetLeadDays,
                    now: currentDate
                ) {
                    ResetCreditsLineView(summary: summary, now: currentDate)
                }
            }
        }
        .padding(.vertical, 9)
        .padding(.horizontal, AccountListMetrics.cardInset)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(highlighted ? Theme.cardHighlightBase : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(highlighted ? Theme.active.opacity(Theme.cardHighlightOpacity(colorScheme)) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(
                            Self.highlightStroke(phase: phase, scheme: colorScheme),
                            lineWidth: Theme.highlightFrameWidth(colorScheme)
                        )
                )
        )
    }
}

enum AccountListMetrics {
    /// How many account cards the popover shows before it scrolls.
    static let maxVisibleCards = 4
    /// Names the scroll content's coordinate space, so cards can report where
    /// they end relative to the top of the list.
    static let coordinateSpace = "accountList"
    /// Fallback cap, used until the first cards have measured themselves and
    /// whenever there are few enough that no cap applies.
    static let maxListHeight: CGFloat = 520

    /// Horizontal inset moved from the list onto each card so the highlighted
    /// card can draw a rounded container without shifting any content.
    static let cardInset: CGFloat = 10
    static let listInset: CGFloat = 3
}

enum AccountLimitLayout {
    static func kinds(
        for provider: Provider,
        snapshot: UsageSnapshot?
    ) -> [UsageWindowKind] {
        switch provider {
        case .claude:
            // Fable (the flagship-model weekly limit) leads when present — it is
            // the scarcest limit, so it earns the first column. Max-only presence
            // gate: absent for non-Max accounts, which then show just 5h + weekly.
            if snapshot?.modelWeekly != nil {
                return [.modelWeekly, .fiveHour, .weekly]
            }
            return [.fiveHour, .weekly]
        case .chatGPT:
            // modelWeekly (Fable) is a Claude Max-only concept; ChatGPT never
            // surfaces it even if a snapshot somehow carried one.
            guard let snapshot else { return [.weekly] }
            let available: [UsageWindowKind] = [.fiveHour, .weekly]
                .filter { snapshot.window(for: $0) != nil }
            return available.isEmpty ? [.weekly] : available
        case .cursor:
            // Cursor's dollars-based card path is introduced in a later task;
            // until then it contributes no rolling-window columns.
            return []
        }
    }

    static func title(for kind: UsageWindowKind, snapshot: UsageSnapshot?) -> String {
        switch kind {
        case .fiveHour: "5h"
        case .weekly: "wk"
        case .modelWeekly: snapshot?.modelWeekly?.label ?? "Fable"
        }
    }
}

/// The small plan tag next to the provider chip (`MAX 20X`, `PRO 5X`, …):
/// neutral ink so it reads as a property, not a second identity color. Never
/// truncates — the account name gives way first.
struct PlanTagView: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(Theme.mono(11))
            .tracking(0.8)
            .foregroundStyle(Theme.creamDim)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.line2, lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}
