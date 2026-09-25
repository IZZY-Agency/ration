import SwiftUI

enum AccountStateBadgeStyle {
    /// Compact menu-bar treatment: a dot for `.current`, terse mono labels
    /// otherwise. Behavior-preserving replacement for AccountCardView's
    /// original inline indicator.
    case compact
    /// Labeled treatment for the Settings detail pane.
    case detailed
}

/// The single source of truth for turning an `AccountViewState` into a visible
/// status indicator. Shared by the menu-bar card and the Settings detail pane.
struct AccountStateBadge: View {
    let state: AccountViewState
    var style: AccountStateBadgeStyle = .detailed
    var now: Date = .now
    var onReauthenticate: (() -> Void)? = nil

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
        Label(Self.compactText(for: state, now: now) ?? "", systemImage: systemImage)
            .font(Theme.mono(12))
            .foregroundStyle(color)
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
