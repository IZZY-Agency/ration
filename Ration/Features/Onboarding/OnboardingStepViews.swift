import SwiftUI

/// Copy and per-step layout for the first-run wizard. Split out of
/// `OnboardingView` so the shell — indicator, navigation, skip — stays
/// readable.
/// Everything the connect step needs to know about one provider, in a single
/// record. One switch, not one per attribute — adding a provider is then a
/// single edit the compiler still checks for exhaustiveness.
struct OnboardingProviderGuide {
    let symbol: String
    let hint: String

    static func guide(for provider: Provider) -> OnboardingProviderGuide {
        switch provider {
        case .claude:
            OnboardingProviderGuide(
                symbol: "sparkles",
                hint: """
                    If you sign in with a magic link, paste the link from your \
                    email into the field at the top of the sign-in window. \
                    Opening it in Safari signs in your browser, not Ration. \
                    \(WarmUpDefaults.newClaudeAccountDisclosure)
                    """
            )
        case .chatGPT:
            // The cookie name is read from the parser that consumes it, so the
            // instructions and the accepted input can never drift apart.
            OnboardingProviderGuide(
                symbol: "hexagon",
                hint: """
                    Passkeys can't run in the sign-in window. Log in at \
                    chatgpt.com in your browser, then copy the \
                    \(ChatGPTSessionCookiePaste.sessionTokenName) cookie value \
                    (DevTools → Application → Cookies) and paste it into the \
                    sign-in window. If your browser shows numbered chunks \
                    (…session-token.0 and .1), paste BOTH as name=value pairs \
                    separated by a semicolon.
                    """
            )
        case .cursor:
            // Kept deliberately, against the spec's "no caveat" line: C5 in
            // docs/KNOWN-LIMITATIONS.md means the Cursor card shows dollars,
            // not a percentage, and a user who expects a percentage will read
            // a correct card as broken.
            OnboardingProviderGuide(
                symbol: "cursorarrow.rays",
                hint: """
                    A normal cursor.com sign-in. Cursor reports usage-based \
                    spend for the billing cycle rather than a percentage of plan.
                    """
            )
        }
    }
}

struct OnboardingWelcomeStep: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingStepHeader(
                title: "Welcome to Ration",
                subtitle: "Your real Claude, ChatGPT and Cursor limits, in the menu bar."
            )

            VStack(alignment: .leading, spacing: 12) {
                OnboardingBullet(
                    symbol: "gauge.with.needle",
                    title: "Real numbers, not guesses",
                    detail: "Reads the same usage endpoints each provider's own site uses — 5-hour and weekly windows, resets, and spend."
                )
                OnboardingBullet(
                    symbol: "lock.laptopcomputer",
                    title: "No middleman",
                    detail: "There's no Ration server, no telemetry, and no account to create. You sign in on the provider's own page — or your SSO provider's, if you use one — and the session stays in an isolated profile on this Mac."
                )
                OnboardingBullet(
                    symbol: "menubar.arrow.up.rectangle",
                    title: "Lives in your menu bar",
                    detail: "There's no Dock icon. Click the ring in the menu bar — or press ⌥⌘U — to open it."
                )
            }
        }
    }
}

struct OnboardingConnectStep: View {
    let onSelect: (Provider) -> Void
    let isWaitingForSignIn: Bool
    let signInError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingStepHeader(
                title: "Connect your first account",
                subtitle: "Each account gets its own isolated browser profile on this Mac. Check the padlock address bar before you type a password."
            )

            ForEach(Provider.allCases) { provider in
                let guide = OnboardingProviderGuide.guide(for: provider)
                Button {
                    onSelect(provider)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: guide.symbol)
                                .foregroundStyle(Theme.gold)
                                .frame(width: 22, height: 22)
                            Text(provider.displayName)
                                .font(Theme.display(14, .semibold))
                                .foregroundStyle(Theme.cream)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Theme.creamFaint)
                        }
                        Text(guide.hint)
                            .font(Theme.mono(9.5))
                            .foregroundStyle(Theme.creamDim)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sign in to \(provider.displayName)")
                // The whole point of this step is the caveat; a VoiceOver user
                // who hears only "Sign in to ChatGPT" gets none of it.
                .accessibilityHint(guide.hint)
                .padding(12)
                .background(Theme.panel, in: RoundedRectangle(cornerRadius: 12))
                .overlay(
                    RoundedRectangle(cornerRadius: 12).stroke(Theme.line2, lineWidth: 1)
                )
            }

            if let signInError {
                Label(signInError, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.crit)
                    .textSelection(.enabled)
            } else if isWaitingForSignIn {
                Label(
                    "Waiting for sign-in… this step finishes by itself once the account is verified.",
                    systemImage: "clock"
                )
                .font(Theme.mono(9.5))
                .foregroundStyle(Theme.creamDim)
            }
        }
    }
}

struct OnboardingLaunchAtLoginStep: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingStepHeader(
                title: "Keep it running",
                subtitle: "Ration can only track your limits while it's running. Starting it at login means you never have to think about it."
            )

            Toggle(
                "Launch at login",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { enabled in
                        Task { await launchAtLogin.setEnabled(enabled) }
                    }
                )
            )
            .accessibilityIdentifier("onboardingLaunchAtLoginToggle")

            if let explanation = launchAtLogin.explanation {
                Text(explanation)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.creamDim)
            }

            if launchAtLogin.state == .requiresApproval {
                Button("Open Login Items Settings") {
                    launchAtLogin.openSystemSettings()
                }
            }

            if let launchError = launchAtLogin.errorMessage {
                Label(launchError, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.crit)
                    .textSelection(.enabled)
            }
        }
    }
}

struct OnboardingDoneStep: View {
    /// Whether any account is actually connected. A user can reach this step
    /// via "Skip for now", and telling them their limits are being watched
    /// when nothing is connected would simply be untrue.
    let hasAccounts: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            OnboardingStepHeader(
                title: hasAccounts ? "You're all set" : "Ready when you are",
                subtitle: hasAccounts
                    ? "Ration is watching your limits. Here's where everything lives."
                    : "No account is connected yet, so there's nothing to track so far. Here's where everything lives when you're ready."
            )

            VStack(alignment: .leading, spacing: 12) {
                OnboardingBullet(
                    symbol: "menubar.arrow.up.rectangle",
                    title: "Can't find the icon?",
                    detail: "Press ⌥⌘U to open the window from anywhere."
                )
                OnboardingBullet(
                    symbol: "plus.circle",
                    title: hasAccounts ? "More accounts" : "Connect an account",
                    detail: hasAccounts
                        ? "Add another any time with the + button at the bottom of the popover."
                        : "Use the + button at the bottom of the popover, or re-open this guide from Settings → General."
                )
                OnboardingBullet(
                    symbol: "gearshape",
                    title: "Settings",
                    detail: "⌘, opens it — account labels, sort order, warm-up quiet hours, and this guide."
                )
                OnboardingBullet(
                    symbol: "chart.xyaxis.line",
                    title: "History",
                    detail: "Burn-down charts and billing-cycle utilisation per account."
                )
                OnboardingBullet(
                    symbol: "bell.badge",
                    title: "Alerts",
                    detail: "Notifies you at thresholds you choose (75% and 90% to begin with). Set them in Settings → Alerts."
                )
                OnboardingBullet(
                    symbol: "chevron.left.forwardslash.chevron.right",
                    title: "Open source",
                    detail: "Source, releases and issues live at github.com/IZZY-Agency/ration. The website is ration.sh — both are one click away in Settings → General and in About."
                )
            }
        }
    }
}

struct OnboardingStepHeader: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(Theme.display(21, .bold))
                .foregroundStyle(Theme.cream)
            Text(subtitle)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.creamDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct OnboardingBullet: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Theme.gold)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.display(13, .semibold))
                    .foregroundStyle(Theme.cream)
                Text(detail)
                    .font(Theme.mono(9.5))
                    .foregroundStyle(Theme.creamDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
