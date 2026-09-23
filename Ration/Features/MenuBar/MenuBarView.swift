import SwiftUI

struct MenuBarView: View {
    let presentations: [AccountPresentation]
    let isRefreshing: Bool
    /// Non-nil while the cleanup queue holds work the user can actually retry — NOT
    /// simply while it is non-empty: entries owned by an in-flight removal, or
    /// referenced by a live account, are filtered out model-side (`isStuckCleanup`).
    /// So nil does not imply an empty queue. Carries the copy AND gates the retry
    /// control, so those two can never disagree.
    let profileCleanupBanner: String?
    /// Non-nil only while the sign-in sessions that actually turned a quit away are
    /// still running, so it cannot contradict the cleanup row above it.
    var signInQuitPauseBanner: String?
    let errorMessage: String?
    /// Warm-up's own row, derived model-side from live accounts, snapshots and
    /// recorded failures — so unlike `errorMessage` it retracts itself when what
    /// it describes stops being true, and cannot be overwritten by an unrelated
    /// failure.
    /// Asked for the banner AS OF a moment, and driven by a `TimelineView`
    /// below: the failure TTL and the reset countdown both move with the clock,
    /// which publishes nothing, so a value captured at render time would freeze.
    var warmUpBanner: (Date) -> WarmUpBanner? = { _ in nil }
    let activeAccounts: [UUID: ActiveUsage]
    var pausedCount: Int = 0
    let onOpen: () -> Void
    let onAddAccount: () -> Void
    let onRefresh: () -> Void
    let onSettings: () -> Void
    let onAbout: () -> Void
    let onHistory: () -> Void
    let onRetryProfileCleanup: () -> Void
    let onQuit: () -> Void
    let onReauthenticate: (UUID) -> Void
    var samples: (UUID, UsageWindowKind) -> [UsageHistorySample] = { _, _ in [] }
    var projection: (UUID, UsageWindowKind) -> Date? = { _, _ in nil }
    var orderingPinByProvider: [Provider: UUID] = [:]
    /// Per-provider lead-days setting for the reset-credits card line
    /// (`AppSettingsData.resetExpiryLeadDays`). Keyed by provider rather than
    /// threaded through as a plain `AppSettings` reference, mirroring
    /// `orderingPinByProvider` — this view stays a pure presentation type with
    /// no direct model dependency.
    var resetLeadDaysByProvider: [Provider: Int] = [:]
    /// Declared last and defaulted so the existing `MenuBarView(...)` call
    /// sites in tests keep compiling; app code always supplies a real action.
    var onOpenSetupGuide: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider().overlay(Theme.line)

            // Its own row, never folded into `errorMessage`: this one carries an
            // action, and an unrelated failure must not be able to hide it.
            if let profileCleanupBanner {
                HStack(spacing: 10) {
                    bannerLabel(profileCleanupBanner)

                    Button("Retry Cleanup", action: onRetryProfileCleanup)
                        .font(Theme.mono(10))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.gold)
                        .help("Delete the leftover profile from the cancelled sign-in")
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                Divider().overlay(Theme.line)
            }

            if let signInQuitPauseBanner {
                bannerLabel(signInQuitPauseBanner)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                Divider().overlay(Theme.line)
            }

            TimelineView(.periodic(from: .now, by: 60)) { context in
                if let banner = warmUpBanner(context.date) {
                    VStack(spacing: 0) {
                        bannerLabel(
                            banner.message,
                            symbol: banner.severity == .critical
                                ? "exclamationmark.triangle.fill"
                                : "pause.circle.fill",
                            tint: banner.severity == .critical ? Theme.crit : Theme.gold
                        )
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        Divider().overlay(Theme.line)
                    }
                } else {
                    EmptyView()
                }
            }

            if let errorMessage {
                bannerLabel(errorMessage)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                Divider().overlay(Theme.line)
            }

            if presentations.isEmpty {
                emptyState
            } else {
                accountList
            }

            Divider().overlay(Theme.line)

            footer
        }
        .frame(width: 540)
        .background(Theme.ink)
        .onAppear(perform: onOpen)
    }

    private func bannerLabel(
        _ message: String,
        symbol: String = "exclamationmark.triangle.fill",
        tint: Color = Theme.crit
    ) -> some View {
        Label(message, systemImage: symbol)
            .font(Theme.mono(10))
            .foregroundStyle(tint)
            .textSelection(.enabled)
            // Up to four rows can coexist above a 520pt account list, and the
            // generic row carries arbitrary `localizedDescription` text. Only the
            // list scrolls, and the 540pt frame constrains WIDTH, so an unbounded
            // message could push the footer off a short display.
            //
            // The cap would otherwise LOSE text — a filesystem error carrying a
            // path, an underlying cause and a recovery hint runs past three lines,
            // and truncated text cannot be selected. The tooltip carries the whole
            // message so nothing is unreachable. A Details disclosure would be the
            // better treatment; tracked rather than built here.
            .lineLimit(3)
            .help(message)
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 3) {
                    Text("$").foregroundStyle(Theme.gold)
                    Text("Ration").foregroundStyle(Theme.cream)
                }
                .font(Theme.mono(14, bold: true))
                .tracking(0.5)
                .textCase(.uppercase)

                Spacer()

                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing")
                } else {
                    HStack(spacing: 6) {
                        Circle().fill(Theme.calm).frame(width: 6, height: 6)
                        Text("live")
                            .font(Theme.mono(10))
                            .tracking(1.4)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.creamFaint)
                    }
                    .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)

            soonestResetLine
        }
    }

    private var soonestResetLine: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let next = SoonestResetSummary.next(from: presentations, now: context.date)
            if let next {
                let kindLabel: String = switch next.kind {
                    case .fiveHour: "5H"
                    case .weekly: "WK"
                    case .modelWeekly: (next.label ?? "Fable").uppercased()
                }
                let kindAccessibilityLabel: String = switch next.kind {
                    case .fiveHour: "5 hour"
                    case .weekly: "weekly"
                    case .modelWeekly: next.label ?? "Fable"
                }
                let remaining = UsageFormatters.remainingUntilReset(next.resetsAt, relativeTo: context.date)

                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.creamFaint)
                    Text("NEXT RESET")
                        .font(Theme.mono(9))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.creamFaint)
                    Text("\(next.accountLabel) · \(kindLabel) · \(remaining)")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.resetAccent)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 13)
                .padding(.bottom, 9)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(
                    "Next reset, \(next.accountLabel) \(kindAccessibilityLabel), in \(remaining)"
                )
            } else {
                EmptyView()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: "circle.dotted.circle")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(Theme.gold)
            Text("No accounts connected")
                .font(Theme.display(15, .semibold))
                .foregroundStyle(Theme.cream)
            Text("Add an account to track real limits.")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.creamDim)
                .multilineTextAlignment(.center)
            if pausedCount > 0 {
                Text("\(pausedCount) paused — manage in Settings")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.creamFaint)
            }
            Button(action: onAddAccount) {
                Text("Add Account")
                    .font(Theme.mono(10.5, bold: true))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(Theme.ink)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.gold, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)

            Button(action: onOpenSetupGuide) {
                Text("New here? Open the setup guide")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.creamDim)
                    .underline()
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the setup guide")
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(20)
    }

    /// Where each account card ENDS inside the scroll content.
    ///
    /// Complete and current: the stack is eager, so this is replaced wholesale
    /// on each layout pass rather than accumulated.
    ///
    /// The list is capped at the first `AccountListMetrics.maxVisibleCards`
    /// cards and scrolls past that. A fixed pixel cap cannot express "four
    /// cards": a Claude card carries three windows and three sparklines while a
    /// Cursor card is a single spend line, so their heights differ by more than
    /// a factor of two and any constant would cut one family off mid-card.
    ///
    /// Bottom EDGE rather than height, because the list is not just cards —
    /// provider section headers and dividers sit between them. Summing card
    /// heights left the cap short by exactly those, which showed three cards
    /// and a sliver of the fourth. An offset already includes everything above
    /// it, so nothing has to be enumerated.
    @State private var cardBottoms: [UUID: CGFloat] = [:]

    /// The height to pin the list to, or nil to let it size to its content.
    private var cappedListHeight: CGFloat? {
        let ordered = AccountGrouping.grouped(
            presentations,
            orderingPinByProvider: orderingPinByProvider
        ).flatMap(\.presentations)

        // Four or fewer: show them ALL, in full. No cap — a constant here is
        // what clipped the fourth card mid-sparkline before.
        guard ordered.count > AccountListMetrics.maxVisibleCards else { return nil }

        let lastVisible = ordered[AccountListMetrics.maxVisibleCards - 1]
        // Until it has reported, hold the old fixed cap rather than guessing —
        // a half-measured list would visibly jump.
        guard let bottom = cardBottoms[lastVisible.id] else {
            return AccountListMetrics.maxListHeight
        }
        return bottom
    }

    /// Eager `VStack`, not `LazyVStack`.
    ///
    /// Laziness is worth nothing here — this list is a handful of accounts, not
    /// a feed — and it actively broke the four-card sizing: a lazy stack builds
    /// only what is on screen, so the fourth card might never report where it
    /// ends and the popover would sit at its fallback height until the user
    /// scrolled. Eager layout makes every card measure itself every pass.
    private var accountList: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(
                    AccountGrouping.grouped(
                        presentations,
                        orderingPinByProvider: orderingPinByProvider
                    )
                ) { group in
                    sectionHeader(group.provider)

                    ForEach(Array(group.presentations.enumerated()), id: \.element.id) { index, presentation in
                        AccountCardView(
                            presentation: presentation,
                            onReauthenticate: { onReauthenticate(presentation.id) },
                            samples: { kind in samples(presentation.id, kind) },
                            projection: { kind in projection(presentation.id, kind) },
                            activeUsage: activeAccounts[presentation.id],
                            resetLeadDays: resetLeadDaysByProvider[presentation.account.provider] ?? 1
                        )
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: AccountCardBottomKey.self,
                                    value: [
                                        presentation.id: proxy
                                            .frame(in: .named(AccountListMetrics.coordinateSpace))
                                            .maxY
                                    ]
                                )
                            }
                        )

                        if index < group.presentations.count - 1 {
                            Divider()
                                .overlay(Theme.line)
                                .padding(.horizontal, AccountListMetrics.cardInset)
                        }
                    }
                }
            }
            .padding(.horizontal, AccountListMetrics.listInset)
            .coordinateSpace(name: AccountListMetrics.coordinateSpace)
        }
        .onPreferenceChange(AccountCardBottomKey.self) { bottoms in
            // REPLACE, never merge. The stack is eager (see `accountList`), so
            // every card reports on every layout pass and this dictionary is a
            // complete picture. Merging kept entries for accounts that had been
            // removed, and — worse — kept a stale position for an account whose
            // place in the list had changed, so reordering or pinning sized the
            // popover from where the fourth card USED to end.
            if cardBottoms != bottoms { cardBottoms = bottoms }
        }
        .modifier(AccountListSizing(cappedHeight: cappedListHeight))
    }

    @ViewBuilder
    private func sectionHeader(_ provider: Provider) -> some View {
        HStack(spacing: 8) {
            Text(provider.displayName)
                .font(Theme.mono(9))
                .tracking(1.4)
                .textCase(.uppercase)          // visual only — a11y label stays normal-cased
                .foregroundStyle(Theme.creamFaint)
            Rectangle()
                .fill(Theme.line)
                .frame(height: 1)
        }
        .padding(.horizontal, AccountListMetrics.cardInset)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(provider.displayName)
        .accessibilityAddTraits(.isHeader)
    }

    private var footer: some View {
        HStack(spacing: 15) {
            footerButton("Add Account", systemImage: "plus", action: onAddAccount)
            footerButton("Refresh", systemImage: "arrow.clockwise", action: onRefresh)
            footerButton("History", systemImage: "chart.xyaxis.line", action: onHistory)
            footerButton("Settings", systemImage: "gearshape", action: onSettings)
            footerButton("About", systemImage: "info.circle", action: onAbout)
            Spacer()
            footerButton("Quit", systemImage: "power", action: onQuit)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    private func footerButton(
        _ label: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.creamDim)
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }
}


/// Where each card ends inside the scroll content, so the list can size itself
/// to a whole number of cards. Keyed by account so a card scrolled out of view
/// keeps its last known position.
private struct AccountCardBottomKey: PreferenceKey {
    static let defaultValue: [UUID: CGFloat] = [:]

    static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}


/// Sizes the account list.
///
/// Two genuinely different modes, which is why this is a modifier rather than
/// one `frame` call. With four or fewer accounts the list takes its natural
/// height — `fixedSize` makes the popover shrink-wrap the content. Past four it
/// is PINNED to a height, and `fixedSize` must not be applied: it makes a
/// `ScrollView` adopt its content's height, which leaves no scrollable region
/// at all. That is why the fifth account used to be clipped and unreachable
/// rather than merely scrolled past.
private struct AccountListSizing: ViewModifier {
    let cappedHeight: CGFloat?

    func body(content: Content) -> some View {
        if let cappedHeight {
            content.frame(height: cappedHeight)
        } else {
            content.fixedSize(horizontal: false, vertical: true)
        }
    }
}
