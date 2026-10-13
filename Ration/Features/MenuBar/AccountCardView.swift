import SwiftUI

/// One account in the Standard popover, as a borderless row.
///
/// Compact: the name line — identity dot, name, plan tag, then on
/// the right IN USE · age, the Claude Code / Codex control and the status
/// badge — and under it the gauges as thin bars, each with its tag, percent
/// and reset side by side. Sparklines and the reset / credits lines follow.
///
/// Folded (`AccountRowMode`): a row that is not in use shrinks to
/// one line around its tightest gauge, with a chevron; the control is hidden
/// until it is expanded again. In use, the row takes the activity green's
/// wash and the green IN USE mark — no frame.
struct AccountCardView: View {
    let presentation: AccountPresentation
    let onReauthenticate: () -> Void
    var samples: (UsageWindowKind) -> [UsageHistorySample] = { _ in [] }
    var projection: (UsageWindowKind) -> Date? = { _ in nil }
    var activeUsage: ActiveUsage? = nil
    /// The Resets feature switch (Settings → General → Features).
    var showsResetCredits: Bool = true
    /// The Usage credits feature switch: the credits line on Claude cards.
    var showsUsageCredits: Bool = true
    var now: Date = .now
    var resetLeadDays: Int = 1
    /// TypeSafe: the low-balance threshold (Settings › Alerts), nil when off.
    var lowBalanceCents: Int? = nil
    /// Cursor only: the account's stored closed cycles, oldest first.
    var cursorHistory: [CursorSpendCycle] = []
    /// A click on a problem badge — the header's STALE click
    /// (`MenuBarView.onFreshnessAction`). nil keeps the badge plain.
    var onProblem: ((FreshnessHelp.Target) -> Void)? = nil
    /// The pointer entered / left the problem badge, or it moved.
    var onProblemHover: (BadgeHoverEvent) -> Void = { _ in }
    /// Claude Code switching (spec §4.4): the tag or the button, Claude only.
    var claudeCode: ClaudeCodeCardState = .none
    var claudeCodeBusy = false
    var onUseInClaudeCode: () -> Void = {}
    /// Codex switching (Codex spec §4.4): the tag or the button, ChatGPT only.
    var codex: CodexCardState = .none
    var codexBusy = false
    var onUseInCodex: () -> Void = {}
    /// The In-use detection switch (Settings › General › Features). Off:
    /// nothing is in use, so nothing folds.
    var inUseDetection: Bool = true
    /// Settings › Display › Popover › Fold accounts not in use. Off unless
    /// the popover passes the setting, so a row drawn alone never folds.
    var foldsAccountsNotInUse: Bool = false
    /// The user expanded this account's folded row (Settings remembers it).
    var isExpanded: Bool = false
    /// The chevron, or a click on a foldable row's first line (folded, its
    /// only line): store expanded (true) or folded (false).
    var onSetExpanded: (Bool) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    /// The pointer is where a click folds or expands the row (its hover
    /// fill): the folded line, or an expanded row's first line.
    @State private var hovered = false

    /// Identity accent: the provider dot (and TypeSafe's provider chip). The
    /// in-use wash and mark use `Theme.active` — state and identity are
    /// separate color channels.
    private var accent: Color { Self.providerChipAccent(for: presentation.account.provider) }

    /// The provider chip's border: its accent, faint enough to frame the chip
    /// without competing with the account name.
    static let providerChipBorderOpacity = 0.16

    /// Vertical padding: compact rows breathe, folded rows are a single
    /// tight line.
    static let rowPadding: CGFloat = 12
    static let foldedPadding: CGFloat = 9
    /// Gauge columns: Claude's three (Fable · 5h · weekly); fewer gauges keep
    /// the same column width, so the bars line up between rows.
    static let gaugeColumns = 3

    var body: some View {
        TimelineView(.periodic(from: now, by: 60)) { context in
            row(relativeTo: context.date)
        }
    }

    /// The green wash: only while in use. The last-used tail is not in use —
    /// it folds like an idle row — so it keeps only its muted caption.
    static func isHighlighted(phase: InUsePhase) -> Bool {
        if case .inUse = phase { return true }
        return false
    }

    /// "Work, Claude" — plus the plan when known: "Work, Claude Max 20x".
    static func nameAccessibilityLabel(for account: AccountRecord) -> String {
        let provider: String = account.provider.displayName
        guard let plan = account.effectivePlan else { return "\(account.label), \(provider)" }
        return "\(account.label), \(provider) \(plan.displayName)"
    }

    /// The provider chip (TypeSafe, in the API section) names the provider,
    /// so it wears that provider's identity accent.
    static func providerChipAccent(for provider: Provider) -> Color { provider.markAccent }

    /// The section header already names Claude, ChatGPT and Cursor; a
    /// TypeSafe account sits under "API", which does not.
    static func showsProviderChip(_ provider: Provider) -> Bool { provider.isAPIAccount }

    private func problemAction(now currentDate: Date) -> AccountBadgeProblemAction? {
        guard let onProblem else { return nil }
        return AccountStateBadge.problemAction(
            for: presentation,
            now: currentDate,
            perform: onProblem,
            hoverChanged: onProblemHover
        )
    }

    private func row(relativeTo date: Date) -> some View {
        let phase = InUsePhase.classify(activeUsage, now: date)
        let mode = AccountRowMode.make(
            phase: phase,
            hasGauges: AccountRowMode.hasGauges(presentation.account.provider),
            inUseDetection: inUseDetection,
            foldsAccountsNotInUse: foldsAccountsNotInUse,
            userExpanded: isExpanded
        )
        // Gauge rows space their lines evenly; Cursor's spend and
        // TypeSafe's balance keep the card's own tighter stack.
        let spacing: CGFloat = AccountRowMode.hasGauges(presentation.account.provider) ? 10 : 8
        let inset = AccountListMetrics.cardInset
        return VStack(alignment: .leading, spacing: 0) {
            if mode.isFolded {
                // Folded, the whole line folds and expands.
                foldToggle(
                    foldedLine(mode: mode, date: date)
                        .padding(.vertical, Self.foldedPadding)
                        .padding(.horizontal, inset),
                    mode: mode
                )
            } else {
                // Expanded, only the first line does — with the row's top
                // padding and half the gap under it. The gauges, their
                // countdowns, the exact time, the sparklines and the lines
                // under them sit outside it: a click there never folds.
                foldToggle(
                    nameLine(phase: phase, mode: mode, date: date)
                        .padding(.top, Self.rowPadding)
                        .padding(.bottom, spacing / 2)
                        .padding(.horizontal, inset),
                    mode: mode
                )
                VStack(alignment: .leading, spacing: spacing) {
                    content(mode: mode, date: date)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, spacing / 2)
                .padding(.bottom, Self.rowPadding)
                .padding(.horizontal, inset)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { ground(phase: phase, mode: mode) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AccountRowCopy.spokenRow(presentation, phase: phase, mode: mode, now: date))
        .accessibilityIdentifier("accountRow")
    }

    /// Where a click folds or expands the row, with the link pointer and the
    /// hover fill that say so — only there. The controls on the line (the
    /// switch, the badge, the chevron) take their own clicks first.
    private func foldToggle(_ line: some View, mode: AccountRowMode) -> some View {
        line
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                if let target = mode.toggledExpansion { onSetExpanded(target) }
            }
            .onHover { hovered = $0 }
            // Folding swaps the line for another under the pointer: the old
            // one reports no exit.
            .onDisappear { hovered = false }
            .pointerStyle(mode.showsChevron ? .link : nil)
    }

    @ViewBuilder
    private func ground(phase: InUsePhase, mode: AccountRowMode) -> some View {
        if Self.isHighlighted(phase: phase) {
            // Edge to edge, past the list's own inset, as one band.
            Rectangle()
                .fill(Theme.cardHighlightBase)
                .overlay(Rectangle().fill(Theme.active.opacity(Theme.cardHighlightOpacity(colorScheme))))
                .padding(.horizontal, -AccountListMetrics.listInset)
        } else if hovered && mode.showsChevron {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.hover)
        }
    }

    // MARK: Lines

    private var identityDot: some View {
        Circle()
            .fill(accent)
            .frame(width: 6, height: 6)
            .accessibilityHidden(true)
    }

    private var providerChip: some View {
        Text(presentation.account.provider.rawValue)
            .font(Theme.mono(10))
            .tracking(0.8)
            .textCase(.uppercase)
            .foregroundStyle(accent)
            .padding(.horizontal, 4)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(accent.opacity(Self.providerChipBorderOpacity), lineWidth: 1)
            )
            .fixedSize()
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var planTag: some View {
        if let tag = PlanChoice.tag(for: presentation.account) {
            PlanTagView(tag: tag, size: 10)
        }
    }

    /// Name · plan … IN USE · age · control · badge · chevron.
    private func nameLine(phase: InUsePhase, mode: AccountRowMode, date: Date) -> some View {
        HStack(spacing: 8) {
            identityDot
            Text(presentation.account.label)
                .font(Theme.display(16, .semibold))
                .foregroundStyle(Theme.cream)
                .lineLimit(1)
                .accessibilityHidden(true)
            if Self.showsProviderChip(presentation.account.provider) {
                providerChip
            }
            planTag
            Spacer(minLength: 8)
            InUseMarkerContent(phase: phase, date: date, style: .inline)
                .accessibilityHidden(true)
            controls
            badge(date)
            if mode.showsChevron {
                chevron(mode)
            }
        }
        .frame(minHeight: 22)
    }

    /// Name · plan … the tightest gauge · badge · chevron. No control: the
    /// switch waits for the row to be expanded.
    private func foldedLine(mode: AccountRowMode, date: Date) -> some View {
        let snapshot = presentation.snapshot
        let kinds = AccountLimitLayout.kinds(for: presentation.account.provider, snapshot: snapshot)
        let tightest = AccountRowMode.tightestKind(kinds: kinds, snapshot: snapshot)
        return HStack(spacing: 8) {
            identityDot
            Text(presentation.account.label)
                .font(Theme.display(15, .semibold))
                .foregroundStyle(Theme.cream)
                .lineLimit(1)
                .accessibilityHidden(true)
            planTag
            Spacer(minLength: 8)
            if let tightest {
                FoldedLimitView(
                    title: AccountLimitLayout.title(for: tightest, snapshot: snapshot),
                    window: snapshot?.window(for: tightest),
                    now: date
                )
                .layoutPriority(1)
                .accessibilityHidden(true)
            }
            // A problem's glyph alone: its words do not fit one line beside
            // a gauge in every language; expanded, the row says them.
            badge(date, iconOnly: true)
            chevron(mode)
        }
        .frame(minHeight: 22)
    }

    /// The Claude Code / Codex control, exactly as on the card before. The
    /// name truncates before it does.
    @ViewBuilder
    private var controls: some View {
        if claudeCode != .none {
            ClaudeCodeCardRow(state: claudeCode, accountLabel: presentation.account.label,
                              busy: claudeCodeBusy, action: onUseInClaudeCode)
                .fixedSize()
                .layoutPriority(1)
        }
        if codex != .none {
            CodexCardRow(state: codex, accountLabel: presentation.account.label,
                         busy: codexBusy, action: onUseInCodex)
                .fixedSize()
                .layoutPriority(1)
        }
    }

    private func badge(_ date: Date, iconOnly: Bool = false) -> some View {
        AccountStateBadge(
            state: presentation.state,
            style: .compact,
            now: date,
            onReauthenticate: onReauthenticate,
            agedOut: AccountStateBadge.showsAgedOut(presentation, now: date),
            problemAction: problemAction(now: date),
            iconOnly: iconOnly
        )
        .fixedSize()
        .layoutPriority(1)
    }

    /// "Expand Work" / "Collapse Work" — the same toggle as a click on the
    /// row's first line, as a button VoiceOver and the keyboard can reach.
    private func chevron(_ mode: AccountRowMode) -> some View {
        let label: String = AccountRowCopy.chevronLabel(mode, label: presentation.account.label) ?? ""
        return Button {
            if let target = mode.toggledExpansion { onSetExpanded(target) }
        } label: {
            Image(systemName: mode.isFolded ? "chevron.down" : "chevron.up")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.creamFaint)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .accessibilityIdentifier("accountRowChevron")
    }

    // MARK: Content

    @ViewBuilder
    private func content(mode: AccountRowMode, date: Date) -> some View {
        if presentation.account.provider == .cursor {
            let spend: CursorSpend? = presentation.snapshot?.cursorSpend
            let trend = CursorSpendTrend.card(closed: cursorHistory, current: spend)
            CursorSpendRowView(spend: spend, now: date, trend: trend)
            CursorSpendTrendLine(trend: trend)
        } else if presentation.account.provider == .typeSafe {
            // Balance first; the expiry line follows the Usage credits
            // switch and the account's lead time.
            TypeSafeCardView(card: TypeSafeCard.make(
                snapshot: presentation.snapshot,
                leadDays: resetLeadDays,
                showsExpiry: showsUsageCredits,
                now: date,
                lowBalanceCents: lowBalanceCents
            ))
        } else {
            gauges(mode: mode, date: date)
            lines(date: date)
        }
    }

    private func gauges(mode: AccountRowMode, date: Date) -> some View {
        let snapshot = presentation.snapshot
        let kinds = AccountLimitLayout.kinds(for: presentation.account.provider, snapshot: snapshot)
        return HStack(alignment: .top, spacing: 16) {
            ForEach(kinds, id: \.self) { kind in
                CompactLimitView(
                    title: AccountLimitLayout.title(for: kind, snapshot: snapshot),
                    window: snapshot?.window(for: kind),
                    kind: kind,
                    now: date,
                    sparkline: mode.showsSparklines ? sparkline(kind) : nil
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(kinds.count..<max(kinds.count, Self.gaugeColumns), id: \.self) { _ in
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: 0)
                    .accessibilityHidden(true)
            }
        }
    }

    /// The trend under a gauge, only when it has one: a flat window's column
    /// stays exactly as tall as one without sparklines. The suppliers are
    /// read once so the gate and the line see the same series (`projection`
    /// reads the clock and can cross the projector's cutoff between calls).
    private func sparkline(_ kind: UsageWindowKind) -> CompactLimitView.Sparkline? {
        let windowSamples = samples(kind)
        let windowProjection = projection(kind)
        guard SparklineVisibility.hasMeaningfulTrend(samples: windowSamples, projection: windowProjection) else { return nil }
        return CompactLimitView.Sparkline(samples: windowSamples, projection: windowProjection)
    }

    /// The reset and credits lines, in their place under the gauges.
    @ViewBuilder
    private func lines(date: Date) -> some View {
        let provider = presentation.account.provider
        let snapshot = presentation.snapshot
        let resets = showsResetCredits
            ? ResetCreditsSummary.make(credits: snapshot?.resetCredits, leadDays: resetLeadDays, now: date) : nil
        // Claude only; the lead time is Claude's Resets one.
        let usage = showsUsageCredits && provider == .claude
            ? UsageCreditsSummary.make(
                credits: snapshot?.usageCredits,
                enabled: snapshot?.usageCreditsEnabled,
                leadDays: resetLeadDays,
                now: date,
                verified: snapshot?.usageCreditsVerified ?? false
            ) : nil
        let codexCredits: CodexCredits? = showsUsageCredits && provider == .chatGPT
            ? snapshot?.codexCredits.flatMap { CodexCreditsCopy.shows($0, now: date) ? $0 : nil } : nil
        if resets != nil || usage != nil || codexCredits != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let resets {
                    ResetCreditsLineView(summary: resets, now: date)
                }
                if let usage {
                    UsageCreditsLineView(summary: usage, now: date)
                }
                if let codexCredits {
                    CodexCreditsLineView(credits: codexCredits)
                }
            }
        }
    }
}

enum AccountListMetrics {
    /// Names the scroll content's coordinate space, so cards can report where
    /// they end relative to the top of the list.
    static let coordinateSpace = "accountList"
    /// Fallback cap, held only while a list long enough to overflow has not
    /// measured itself yet (`cappedHeight`), so the popover does not open
    /// tall and then jump.
    static let maxListHeight: CGFloat = 520
    /// Past this many cards an unmeasured list MIGHT overflow the screen, so
    /// it starts at the fallback cap; up to it, it sizes to its content
    /// straight away.
    static let plausibleOverflowCount = 4

    /// The frame a surface adds around its content: the ⌥⌘U window's title
    /// bar, 32 pt (`NSWindow.frameRect(forContentRect:styleMask:)` on
    /// macOS 26/27), which also covers the popover's own frame — its arrow
    /// and glass inset, about 26 pt (measured: a popover of 680 pt where the
    /// window around the same content measured 686).
    static let surfaceFrame: CGFloat = 32
    /// Keeps the surface short of the Dock or the screen's bottom edge.
    static let screenMargin: CGFloat = 12
    /// The popover's room when no screen has been asked — tests, snapshots,
    /// the SwiftUI scene — so none of them depends on the screen it runs on.
    /// About a 14-inch MacBook Pro's.
    static let defaultRoom: CGFloat = 900
    /// The least the list is given, however short the screen and however
    /// many banners: a section header and a folded row. Never a negative
    /// frame.
    static let minimumListHeight: CGFloat = 80

    /// How tall a surface's content may be on a screen: its visible height
    /// (menu bar and Dock already out) less the surface's frame and the
    /// margin.
    static func room(visibleFrame: CGRect) -> CGFloat {
        visibleFrame.height - surfaceFrame - screenMargin
    }

    /// What the room leaves the list once the popover's own rows are out —
    /// the header, switch lines, banners, status strip and footer, as
    /// DRAWN (`chrome`), so a banner that appears or expands takes its room
    /// from the list. Nil while the chrome has not been measured.
    static func listAvailableHeight(room: CGFloat, chrome: CGFloat?) -> CGFloat? {
        chrome.map { max(minimumListHeight, room - $0) }
    }

    /// The height to pin the list to, or nil to let it take its natural
    /// height.
    ///
    /// The list is pinned only when its content would run past `available`:
    /// then to the bottom of the last card that fits whole, so no card is cut
    /// mid-gauge — or to `available` itself when not even the first card fits.
    ///
    /// - Parameters:
    ///   - cardBottoms: where each card ends in the scroll content, top to
    ///     bottom; nil for a card that has not reported yet. A bottom edge,
    ///     not a height: it already includes the section headers and
    ///     dividers above the card.
    ///   - contentBottom: where the content ends — past the last card when a
    ///     section footer follows it; nil until measured.
    ///   - available: the list's room (`listAvailableHeight`); nil until the
    ///     chrome has been measured.
    static func cappedHeight(cardBottoms: [CGFloat?], contentBottom: CGFloat?, available: CGFloat?) -> CGFloat? {
        let measured = cardBottoms.compactMap { $0 }
        guard let available, measured.count == cardBottoms.count else {
            // Until every card and the chrome have measured themselves, hold
            // the fallback only when an overflow is plausible — a
            // half-measured list would visibly jump.
            guard cardBottoms.count > plausibleOverflowCount else { return nil }
            return min(available ?? maxListHeight, maxListHeight)
        }
        guard let last = measured.last else { return nil }
        if max(last, contentBottom ?? last) <= available { return nil }
        // Top to bottom, so the last that fits is the lowest — never above
        // the first card's bottom. None fits, not even the first: the room.
        return measured.last { $0 <= available } ?? available
    }

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
        case .cursor, .typeSafe:
            // Dollars-based cards (Cursor's spend row, TypeSafe's balance):
            // no rolling-window columns.
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

/// The small plan tag next to the account name (`MAX 20X`, `PRO 5X`, …):
/// neutral ink so it reads as a property, not a second identity color. Never
/// truncates — the account name gives way first.
struct PlanTagView: View {
    let tag: String
    /// The popover's rows draw it at 10; elsewhere 11.
    var size: CGFloat = 11

    var body: some View {
        Text(tag)
            .font(Theme.mono(size))
            .tracking(0.8)
            .foregroundStyle(Theme.creamDim)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, size < 11 ? 4 : 5)
            .padding(.vertical, size < 11 ? 0.5 : 1.5)
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.line2, lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}
