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
    /// `NotificationAccess.problem` — alerts are on but can't notify: macOS
    /// refuses (→ System Settings) or was never asked (→ ask). The drop still
    /// works, so the row says only that alerts cannot NOTIFY.
    var notificationProblem: NotificationAccess.Problem? = nil
    var onOpenNotificationSettings: () -> Void = {}
    var onAllowNotifications: () -> Void = {}
    /// The attention drop is on screen. The panel never takes focus, so its ✕
    /// is mouse-only; this offers the same dismissal from the keyboard.
    var attentionDropShowing: Bool = false
    var onDismissAttentionDrop: () -> Void = {}

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
                        .font(Theme.mono(12))
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

            if let notificationProblem {
                HStack(spacing: 10) {
                    bannerLabel(
                        notificationProblem.popoverBanner,
                        symbol: "bell.slash.fill",
                        tint: Theme.warn
                    )

                    switch notificationProblem {
                    case .blocked:
                        Button("Notification Settings", action: onOpenNotificationSettings)
                            .font(Theme.mono(12))
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.gold)
                            .help(NotificationAccess.openSettingsTitle)
                    case .needsPermission:
                        Button(NotificationAccess.allowTitle, action: onAllowNotifications)
                            .font(Theme.mono(12))
                            .buttonStyle(.plain)
                            .foregroundStyle(Theme.gold)
                            .help(NotificationAccess.allowHelp)
                            .accessibilityIdentifier("popoverAllowNotificationsButton")
                    }
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 8)
                Divider().overlay(Theme.line)
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
        BannerMessage(message: message, symbol: symbol, tint: tint)
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 3) {
                    Text("$").foregroundStyle(Theme.gold)
                    Text("Ration").foregroundStyle(Theme.cream)
                }
                .font(Theme.mono(16, bold: true))
                .tracking(0.5)
                .textCase(.uppercase)

                Spacer()

                if attentionDropShowing {
                    Button(action: onDismissAttentionDrop) {
                        Label("Dismiss Alerts", systemImage: "xmark")
                            .font(Theme.mono(11))
                            .tracking(0.6)
                            .textCase(.uppercase)
                            .foregroundStyle(Theme.creamDim)
                    }
                    .buttonStyle(.plain)
                    // Same action as the drop's ✕ — the panel itself can
                    // never be focused, so the keyboard route lives here.
                    .keyboardShortcut("d", modifiers: .command)
                    .help("Dismiss the alerts drop until these limits reset (⌘D)")
                    .accessibilityLabel("Dismiss alerts")
                    .padding(.trailing, 12)
                }

                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Refreshing")
                } else {
                    // Evidence ages with the clock, which publishes nothing —
                    // re-derive periodically so LIVE turns STALE on its own.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        if let freshness = HeaderFreshness.make(
                            presentations: presentations,
                            now: context.date
                        ) {
                            freshnessIndicator(freshness)
                        } else {
                            EmptyView()
                        }
                    }
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)

            soonestResetLine
        }
    }

    private func freshnessIndicator(_ freshness: HeaderFreshness) -> some View {
        let (dot, label): (Color, Color) = switch freshness {
            case .live: (Theme.calm, Theme.creamFaint)
            case .stale: (Theme.warn, Theme.warn)
            case .offline: (Theme.crit, Theme.crit)
        }
        return HStack(spacing: 6) {
            Circle().fill(dot).frame(width: 6, height: 6)
            Text(freshness.text)
                .font(Theme.mono(12))
                .tracking(1.4)
                .foregroundStyle(label)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(freshness.accessibilityLabel)
        .accessibilityIdentifier("headerFreshness")
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
                let remaining = UsageFormatters.remainingUntilReset(next.resetsAt, relativeTo: context.date)

                HStack(spacing: 6) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.creamFaint)
                    Text("NEXT RESET")
                        .font(Theme.mono(11))
                        .tracking(1.2)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.creamFaint)
                    Text("\(next.accountLabel) · \(kindLabel) · \(remaining)")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.resetAccent)
                }
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 13)
                .padding(.bottom, 9)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(next.accessibilityLabel(now: context.date))
            } else {
                EmptyView()
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 11) {
            Image(systemName: "circle.dotted.circle")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(Theme.gold)
            Text("No accounts connected")
                .font(Theme.display(17, .semibold))
                .foregroundStyle(Theme.cream)
            Text("Add an account to track real limits.")
                .font(Theme.mono(13))
                .foregroundStyle(Theme.creamDim)
                .multilineTextAlignment(.center)
            if pausedCount > 0 {
                Text("\(pausedCount) paused — manage in Settings")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamFaint)
            }
            Button(action: onAddAccount) {
                Text("Add Account")
                    .font(Theme.mono(12.5, bold: true))
                    .textCase(.uppercase)
                    .tracking(0.5)
                    .foregroundStyle(Theme.onGold)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Theme.gold, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)

            Button(action: onOpenSetupGuide) {
                Text("New here? Open the setup guide")
                    .font(Theme.mono(12))
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
                .font(Theme.mono(11))
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
            footerButton("Refresh", systemImage: "arrow.clockwise", shortcut: "r", action: onRefresh)
            footerButton("History", systemImage: "chart.xyaxis.line", action: onHistory)
            footerButton("Settings", systemImage: "gearshape", shortcut: ",", action: onSettings)
            footerButton("About", systemImage: "info.circle", action: onAbout)
            Spacer()
            footerButton("Quit", systemImage: "power", shortcut: "q", action: onQuit)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
    }

    /// `shortcut` is a ⌘ key equivalent, live while the popover is key — it
    /// sits on the button itself, so it runs exactly what a click runs.
    private func footerButton(
        _ label: String,
        systemImage: String,
        shortcut: KeyEquivalent? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.creamDim)
                // 22: the widest footer glyph at 16pt (chart.xyaxis.line)
                // measures 22×18, so a 20pt box let it spill past its own
                // hit target.
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(shortcut.map { "\(label) (⌘\(String($0.character).uppercased()))" } ?? label)
        .modifier(CommandShortcut(key: shortcut))
    }
}

/// `.keyboardShortcut(key, modifiers: .command)` when there is a key.
private struct CommandShortcut: ViewModifier {
    let key: KeyEquivalent?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(key, modifiers: .command)
        } else {
            content
        }
    }
}

/// Whether a capped banner actually lost text — the Details toggle shows only
/// then. Half a point of slack absorbs layout rounding.
enum BannerDisclosure {
    static func isTruncated(fullHeight: CGFloat, cappedHeight: CGFloat) -> Bool {
        fullHeight > cappedHeight + 0.5
    }
}

/// One banner row's message.
///
/// Up to four banners can coexist above a 520 pt account list, and the
/// generic one carries arbitrary `localizedDescription` text. Only the list
/// scrolls, and the 540 pt frame constrains WIDTH, so an unbounded message
/// could push the footer off a short display — hence the three-line cap.
///
/// The cap would otherwise LOSE text (a filesystem error carrying a path, a
/// cause and a recovery hint runs past three lines), and tooltips do not
/// render on macOS 27, so the `.help` alone left it unreachable. A hidden,
/// unconstrained copy measures the full height; when it exceeds the capped
/// one, a Details toggle expands the message inline.
private struct BannerMessage: View {
    let message: String
    let symbol: String
    let tint: Color

    @State private var isExpanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var cappedHeight: CGFloat = 0

    private static let lineCap = 3

    private var label: some View {
        Label(message, systemImage: symbol)
            .font(Theme.mono(12))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            label
                .foregroundStyle(tint)
                .textSelection(.enabled)
                .lineLimit(isExpanded ? nil : Self.lineCap)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                    cappedHeight = $0
                }
                .background(alignment: .topLeading) {
                    // Same width, no line cap: how tall the message REALLY is.
                    label
                        .fixedSize(horizontal: false, vertical: true)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: {
                            fullHeight = $0
                        }
                        .accessibilityHidden(true)
                }
                .help(message)

            if isExpanded || BannerDisclosure.isTruncated(fullHeight: fullHeight, cappedHeight: cappedHeight) {
                Button(isExpanded ? "Hide Details" : "Details") {
                    isExpanded.toggle()
                }
                .font(Theme.mono(11))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.gold)
                .accessibilityHint(isExpanded ? "Collapses the message" : "Shows the whole message")
            }
        }
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
