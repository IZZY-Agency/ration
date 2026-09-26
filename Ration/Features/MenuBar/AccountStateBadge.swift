import SwiftUI

enum AccountStateBadgeStyle {
    /// Compact menu-bar treatment: a dot for `.current`, terse mono labels
    /// otherwise. Behavior-preserving replacement for AccountCardView's
    /// original inline indicator.
    case compact
    /// Labeled treatment for the Settings detail pane.
    case detailed
}

/// A popover badge that shows a problem is a button: the header's STALE click
/// for this one account (close the popover, open Settings on it). Built only
/// by `AccountStateBadge.problemAction(for:now:locale:perform:hoverChanged:)`.
struct AccountBadgeProblemAction {
    /// "Work: stale. Opens its settings."
    let spokenLabel: String
    let open: () -> Void
    /// The pointer entered or left the badge, or the badge moved under it.
    let hoverChanged: (BadgeHoverEvent) -> Void
}

/// What a problem badge reports to the popover, which draws its hint.
enum BadgeHoverEvent: Equatable {
    /// The pointer entered; the badge's frame in `MenuBarView.popoverSpace`.
    case entered(CGRect)
    case exited
    /// The badge moved while hovered (the list scrolled).
    case moved
}

/// A problem badge's hover hint, as drawn: which account, under which frame.
struct BadgeHint: Equatable {
    let id: UUID
    /// The badge, in `MenuBarView.popoverSpace`.
    let frame: CGRect
}

/// The popover's badge-hint state, pure so it can be tested. Keyed by
/// account: a late "exited" from one badge cannot hide the hint another just
/// brought up. The view arms the delay on `.entered` and calls
/// `delayElapsed` when it runs out.
struct BadgeHintState: Equatable {
    private(set) var hoveredID: UUID?
    private(set) var hoveredFrame: CGRect = .zero
    private(set) var shown: BadgeHint?

    mutating func handle(_ event: BadgeHoverEvent, for id: UUID) {
        switch event {
        case let .entered(frame):
            hoveredID = id
            hoveredFrame = frame
            shown = nil
        case .exited, .moved:
            // `.moved`: dismissed rather than re-anchored — the badge may
            // have scrolled out of the list's visible area.
            guard hoveredID == id else { return }
            hoveredID = nil
            shown = nil
        }
    }

    mutating func delayElapsed(for id: UUID) {
        guard hoveredID == id else { return }
        shown = BadgeHint(id: id, frame: hoveredFrame)
    }
}

/// The single source of truth for turning an `AccountViewState` into a visible
/// status indicator. Shared by the menu-bar card and the Settings detail pane.
struct AccountStateBadge: View {
    let state: AccountViewState
    var style: AccountStateBadgeStyle = .detailed
    var now: Date = .now
    var onReauthenticate: (() -> Void)? = nil
    /// Compact style only: `.current` / `.loading` over a snapshot that has
    /// aged out (`showsAgedOut`). The header counts such an account, so the
    /// badge draws the stale word instead of the live dot or the spinner.
    var agedOut: Bool = false
    /// Compact style only: makes a problem badge clickable. nil = plain.
    var problemAction: AccountBadgeProblemAction? = nil

    @State private var problemHovered = false

    /// `.current` / `.loading` whose data the header judges aged out: drawn
    /// as stale. Other states already draw their own problem.
    static func showsAgedOut(_ presentation: AccountPresentation, now: Date) -> Bool {
        switch presentation.state {
        case .current, .loading:
            return HeaderFreshness.isAgedOut(presentation, now: now)
        case .stale, .reauthenticationRequired, .rateLimited, .integrationChanged, .unavailable:
            return false
        }
    }

    /// The compact badge's words for this account, aged-out included.
    static func compactProblemText(
        for presentation: AccountPresentation,
        now: Date,
        locale: Locale = .current
    ) -> String? {
        if showsAgedOut(presentation, now: now) {
            return LocalizedStringResource.accountStateStale.string(in: locale)
        }
        return compactText(for: presentation.state, now: now, locale: locale)
    }

    /// Where a click on this account's badge goes: `.account(id)`, exactly
    /// the header's STALE target. Non-nil for exactly the accounts the header
    /// counts (`AttentionCause.classify`, the header's own rule), except a
    /// sign-in: that badge is already its own Sign In button.
    static func problemTarget(for presentation: AccountPresentation, now: Date) -> FreshnessHelp.Target? {
        guard presentation.state != .reauthenticationRequired else { return nil }
        guard AttentionCause.classify(presentation, now: now) != nil else { return nil }
        return .account(presentation.id)
    }

    /// The badge's click for this account, or nil when it stays plain.
    static func problemAction(
        for presentation: AccountPresentation,
        now: Date,
        locale: Locale = .current,
        perform: @escaping (FreshnessHelp.Target) -> Void,
        hoverChanged: @escaping (BadgeHoverEvent) -> Void = { _ in }
    ) -> AccountBadgeProblemAction? {
        guard let target = problemTarget(for: presentation, now: now) else { return nil }
        guard let stateText = compactProblemText(for: presentation, now: now, locale: locale) else { return nil }
        let spoken: String = LocalizedStringResource
            .accountStateOpensSettingsSpoken(presentation.account.label, stateText)
            .string(in: locale)
        return AccountBadgeProblemAction(
            spokenLabel: spoken,
            open: {
                perform(target)
            },
            hoverChanged: hoverChanged
        )
    }

    /// The semantic tint for a state, independent of layout. Used by the
    /// sidebar's status dot as well as this badge.
    static func tint(for state: AccountViewState) -> Color {
        switch state {
        case .loading: Theme.creamFaint
        case .current: Theme.calm
        case .stale: Theme.warn
        case .reauthenticationRequired: Theme.gold
        case .rateLimited: Theme.warn
        case .integrationChanged: Theme.crit
        case .unavailable: Theme.creamFaint
        }
    }

    var body: some View {
        switch style {
        case .compact: compactBody
        case .detailed: detailedBody
        }
    }

    // MARK: Compact (menu bar — matches the original stateIndicator)

    @ViewBuilder
    private var compactBody: some View {
        if agedOut {
            compactLabel(
                text: LocalizedStringResource.accountStateStale.string(in: .current),
                systemImage: "clock.badge.exclamationmark",
                color: Theme.warn
            )
        } else {
            compactStateBody
        }
    }

    @ViewBuilder
    private var compactStateBody: some View {
        switch state {
        case .loading:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Refreshing")
        case .current:
            Circle()
                .fill(Theme.calm)
                .frame(width: 7, height: 7)
                .accessibilityLabel("Current")
        case .stale:
            compactLabel(systemImage: "clock.badge.exclamationmark", color: Theme.warn)
        case .reauthenticationRequired:
            reauthControl(compact: true)
        case .rateLimited:
            compactLabel(systemImage: "hourglass", color: Theme.warn)
        case .integrationChanged:
            compactLabel(systemImage: "wrench.and.screwdriver", color: Theme.crit)
        case .unavailable:
            compactLabel(systemImage: "exclamationmark.circle", color: Theme.creamFaint)
        }
    }

    private func compactLabel(systemImage: String, color: Color) -> some View {
        compactLabel(text: Self.compactText(for: state, now: now) ?? "", systemImage: systemImage, color: color)
    }

    @ViewBuilder
    private func compactLabel(text: String, systemImage: String, color: Color) -> some View {
        let label = Label(text, systemImage: systemImage)
            .font(Theme.mono(12))
            .foregroundStyle(color)
        if let problemAction {
            problemButton(label, action: problemAction)
        } else {
            label
        }
    }

    /// The header STALE word's treatment: hover highlight, link pointer, a
    /// custom hover hint (drawn by the popover — `.help` tooltips do not show
    /// on macOS 27), one VoiceOver button.
    private func problemButton(
        _ label: some View,
        action: AccountBadgeProblemAction
    ) -> some View {
        Button {
            setProblemHovered(false, action: action)
            action.open()
        } label: {
            label
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(problemHovered ? Theme.hover : Color.clear)
                        .padding(.horizontal, -5)
                        .padding(.vertical, -3)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onGeometryChange(for: CGRect.self) { proxy in
            proxy.frame(in: .named(MenuBarView.popoverSpace))
        } action: { frame in
            frameInPopover = frame
            // Scrolling moves the badge without a hover event: tell the
            // popover, which dismisses the hint rather than leave it behind.
            if problemHovered {
                action.hoverChanged(.moved)
            }
        }
        .onHover { inside in
            setProblemHovered(inside, action: action)
        }
        .onDisappear {
            setProblemHovered(false, action: action)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(action.spokenLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("accountStateBadgeButton")
    }

    @State private var frameInPopover: CGRect = .zero

    private func setProblemHovered(_ inside: Bool, action: AccountBadgeProblemAction) {
        guard problemHovered != inside else { return }
        problemHovered = inside
        if inside {
            action.hoverChanged(.entered(frameInPopover))
        } else {
            action.hoverChanged(.exited)
        }
    }

    /// The compact badge's words ("stale", "retry in 5 minutes" …); nil for
    /// the states drawn without text (spinner, dot, Sign In).
    static func compactText(for state: AccountViewState, now: Date, locale: Locale = .current) -> String? {
        switch state {
        case .loading, .current, .reauthenticationRequired:
            return nil
        case .stale:
            return LocalizedStringResource.accountStateStale.string(in: locale)
        case let .rateLimited(retryAt):
            guard let retryAt else { return LocalizedStringResource.accountStateRateLimited.string(in: locale) }
            let when: String = UsageFormatters.relativeReset(retryAt, relativeTo: now, locale: locale)
            return LocalizedStringResource.accountStateRetry(when).string(in: locale)
        case .integrationChanged:
            return LocalizedStringResource.accountStateNeedsUpdate.string(in: locale)
        case .unavailable:
            return LocalizedStringResource.accountStateUnavailable.string(in: locale)
        }
    }

    // MARK: Detailed (Settings detail pane)

    @ViewBuilder
    private var detailedBody: some View {
        switch state {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                labelText(Self.detailedText(for: state, now: now) ?? "", Theme.creamDim)
            }
        case .reauthenticationRequired:
            reauthControl(compact: false)
        default:
            dotLabel(Self.detailedText(for: state, now: now) ?? "", Self.tint(for: state))
        }
    }

    /// The Settings pane's label ("Active", "Rate-limited · retry in 5
    /// minutes" …); nil for re-authentication, which is a control.
    static func detailedText(for state: AccountViewState, now: Date, locale: Locale = .current) -> String? {
        let resource: LocalizedStringResource
        switch state {
        case .loading: resource = .badgeRefreshing
        case .current: resource = .badgeActive
        case .stale: resource = .badgeStale
        case .reauthenticationRequired: return nil
        case let .rateLimited(retryAt):
            if let retryAt {
                let when: String = UsageFormatters.relativeReset(retryAt, relativeTo: now, locale: locale)
                resource = .badgeRateLimitedRetry(when)
            } else {
                resource = .badgeRateLimited
            }
        case .integrationChanged: resource = .badgeNeedsUpdate
        case .unavailable: resource = .badgeNoData
        }
        return resource.string(in: locale)
    }

    static func signInNeededText(locale: Locale = .current) -> String {
        LocalizedStringResource.badgeSignInNeeded.string(in: locale)
    }

    @ViewBuilder
    private func reauthControl(compact: Bool) -> some View {
        if let onReauthenticate {
            Button("Sign In", action: onReauthenticate)
                .font(Theme.mono(compact ? 13 : 14))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.gold)
        } else {
            dotLabel(Self.signInNeededText(), Theme.gold)
        }
    }

    private func dotLabel(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            labelText(text, color)
        }
    }

    private func labelText(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(Theme.mono(13))
            .tracking(0.4)
            .foregroundStyle(color)
    }
}
