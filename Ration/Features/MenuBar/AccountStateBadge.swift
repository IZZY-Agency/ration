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
            Label("stale", systemImage: "clock.badge.exclamationmark")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.warn)
        case .reauthenticationRequired:
            reauthControl(compact: true)
        case let .rateLimited(retryAt):
            Label(
                retryAt.map { "retry \(UsageFormatters.relativeReset($0, relativeTo: now))" }
                    ?? "rate limited",
                systemImage: "hourglass"
            )
            .font(Theme.mono(12))
            .foregroundStyle(Theme.warn)
        case .integrationChanged:
            Label("needs update", systemImage: "wrench.and.screwdriver")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.crit)
        case .unavailable:
            Label("unavailable", systemImage: "exclamationmark.circle")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamFaint)
        }
    }

    // MARK: Detailed (Settings detail pane)

    @ViewBuilder
    private var detailedBody: some View {
        switch state {
        case .loading:
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                labelText("Refreshing", Theme.creamDim)
            }
        case .current:
            dotLabel("Active", Theme.calm)
        case .stale:
            dotLabel("Stale", Theme.warn)
        case .reauthenticationRequired:
            reauthControl(compact: false)
        case let .rateLimited(retryAt):
            dotLabel(
                retryAt.map { "Rate-limited · retry \(UsageFormatters.relativeReset($0, relativeTo: now))" }
                    ?? "Rate-limited",
                Theme.warn
            )
        case .integrationChanged:
            dotLabel("Needs update", Theme.crit)
        case .unavailable:
            dotLabel("No data", Theme.creamFaint)
        }
    }

    @ViewBuilder
    private func reauthControl(compact: Bool) -> some View {
        if let onReauthenticate {
            Button("Sign In", action: onReauthenticate)
                .font(Theme.mono(compact ? 13 : 14))
                .buttonStyle(.plain)
                .foregroundStyle(Theme.gold)
        } else {
            dotLabel("Sign-in needed", Theme.gold)
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
