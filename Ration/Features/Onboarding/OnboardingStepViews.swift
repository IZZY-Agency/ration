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

    static func guide(
        for provider: Provider,
        warmUpEnabled: Bool = true,
        locale: Locale = .current
    ) -> OnboardingProviderGuide {
        switch provider {
        case .claude:
            // One entry per warm-up state: the magic-link advice and the
            // warm-up disclosure read as one block, and each entry repeats
            // `warmUp.disclosure.on/off` word for word (a test holds them
            // together).
            let hint: LocalizedStringResource = warmUpEnabled
                ? .onboardingHintClaudeWarmUpOn
                : .onboardingHintClaudeWarmUpOff
            return OnboardingProviderGuide(symbol: "sparkles", hint: hint.string(in: locale))
        case .chatGPT:
            // The cookie name is read from the parser that consumes it, so the
            // instructions and the accepted input can never drift apart.
            let hint = LocalizedStringResource.onboardingHintChatGPT(ChatGPTSessionCookiePaste.sessionTokenName)
            return OnboardingProviderGuide(symbol: "hexagon", hint: hint.string(in: locale))
        case .cursor:
            // Kept deliberately: as docs/KNOWN-LIMITATIONS.md explains, the
            // Cursor card shows dollars, not a percentage, and a user who
            // expects a percentage will read a correct card as broken.
            return OnboardingProviderGuide(
                symbol: "cursorarrow.rays",
                hint: LocalizedStringResource.onboardingHintCursor.string(in: locale)
            )
        }
    }
}

/// A step's heading and bullets, resolved in one language. Built by each
/// step's `copy`/`header` so the views stay layout-only and the text is
/// testable in every language.
struct OnboardingStepCopy: Equatable {
    let title: String
    let subtitle: String
    var bullets: [OnboardingBulletCopy] = []
}

struct OnboardingBulletCopy: Equatable {
    let symbol: String
    let title: String
    let detail: String
}

struct OnboardingWelcomeStep: View {
    static func copy(locale: Locale = .current) -> OnboardingStepCopy {
        OnboardingStepCopy(
            title: LocalizedStringResource.onboardingWelcomeTitle.string(in: locale),
            subtitle: LocalizedStringResource.onboardingWelcomeSubtitle.string(in: locale),
            bullets: [
                OnboardingBulletCopy(
                    symbol: "gauge.with.needle",
                    title: LocalizedStringResource.onboardingWelcomeRealNumbersTitle.string(in: locale),
                    detail: LocalizedStringResource.onboardingWelcomeRealNumbersDetail.string(in: locale)
                ),
                OnboardingBulletCopy(
                    symbol: "lock.laptopcomputer",
                    title: LocalizedStringResource.onboardingWelcomeNoMiddlemanTitle.string(in: locale),
                    detail: LocalizedStringResource.onboardingWelcomeNoMiddlemanDetail.string(in: locale)
                ),
                OnboardingBulletCopy(
                    symbol: "menubar.arrow.up.rectangle",
                    title: LocalizedStringResource.onboardingWelcomeMenuBarTitle.string(in: locale),
                    detail: LocalizedStringResource.onboardingWelcomeMenuBarDetail.string(in: locale)
                ),
            ]
        )
    }

    var body: some View {
        OnboardingCopyStack(copy: Self.copy(), spacing: 16, bulletSpacing: 12)
    }
}

struct OnboardingConnectStep: View {
    let onSelect: (Provider) -> Void
    let isWaitingForSignIn: Bool
    let signInError: String?
    /// The global Claude warm-up switch, for the Claude hint's disclosure.
    var warmUpEnabled: Bool = true

    /// Each provider's icon wears that provider's identity accent, like Add
    /// Account — it was Claude gold for every provider.
    static func iconAccent(for provider: Provider) -> Color { provider.markAccent }

    static func header(locale: Locale = .current) -> OnboardingStepCopy {
        OnboardingStepCopy(
            title: LocalizedStringResource.onboardingConnectTitle.string(in: locale),
            subtitle: LocalizedStringResource.onboardingConnectSubtitle.string(in: locale)
        )
    }

    static func waitingText(locale: Locale = .current) -> String {
        LocalizedStringResource.onboardingConnectWaiting.string(in: locale)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            let header = Self.header()
            OnboardingStepHeader(title: header.title, subtitle: header.subtitle)

            ForEach(Provider.allCases) { provider in
                let guide = OnboardingProviderGuide.guide(for: provider, warmUpEnabled: warmUpEnabled)
                Button {
                    onSelect(provider)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 10) {
                            Image(systemName: guide.symbol)
                                .foregroundStyle(Self.iconAccent(for: provider))
                                .frame(width: 22, height: 22)
                            Text(provider.displayName)
                                .font(Theme.display(16, .semibold))
                                .foregroundStyle(Theme.cream)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(Theme.creamFaint)
                        }
                        Text(guide.hint)
                            .font(Theme.mono(11.5))
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
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.crit)
                    .textSelection(.enabled)
            } else if isWaitingForSignIn {
                Label(Self.waitingText(), systemImage: "clock")
                .font(Theme.mono(11.5))
                .foregroundStyle(Theme.creamDim)
            }
        }
    }
}

struct OnboardingLaunchAtLoginStep: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginController

    static func header(locale: Locale = .current) -> OnboardingStepCopy {
        OnboardingStepCopy(
            title: LocalizedStringResource.onboardingLaunchTitle.string(in: locale),
            subtitle: LocalizedStringResource.onboardingLaunchSubtitle.string(in: locale)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let header = Self.header()
            OnboardingStepHeader(title: header.title, subtitle: header.subtitle)

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
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)
            }

            if launchAtLogin.state == .requiresApproval {
                Button("Open Login Items Settings") {
                    launchAtLogin.openSystemSettings()
                }
            }

            if let launchError = launchAtLogin.errorMessage {
                Label(launchError, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.mono(12))
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

    /// The bullet titles for Settings, History and Alerts are the names those
    /// windows and panes carry, from the same entries.
    static func copy(hasAccounts: Bool, locale: Locale = .current) -> OnboardingStepCopy {
        let title: LocalizedStringResource = hasAccounts ? .onboardingDoneTitleReady : .onboardingDoneTitleEmpty
        let subtitle: LocalizedStringResource = hasAccounts ? .onboardingDoneSubtitleReady : .onboardingDoneSubtitleEmpty
        let accountsTitle: LocalizedStringResource = hasAccounts
            ? .onboardingDoneMoreAccountsTitle
            : .onboardingDoneConnectAccountTitle
        let accountsDetail: LocalizedStringResource = hasAccounts
            ? .onboardingDoneMoreAccountsDetail
            : .onboardingDoneConnectAccountDetail
        return OnboardingStepCopy(
            title: title.string(in: locale),
            subtitle: subtitle.string(in: locale),
            bullets: [
                OnboardingBulletCopy(
                    symbol: "menubar.arrow.up.rectangle",
                    title: LocalizedStringResource.onboardingDoneFindIconTitle.string(in: locale),
                    detail: LocalizedStringResource.onboardingDoneFindIconDetail.string(in: locale)
                ),
                OnboardingBulletCopy(
                    symbol: "plus.circle",
                    title: accountsTitle.string(in: locale),
                    detail: accountsDetail.string(in: locale)
                ),
                OnboardingBulletCopy(
                    symbol: "gearshape",
                    title: LocalizedStringResource("Settings").string(in: locale),
                    detail: LocalizedStringResource.onboardingDoneSettingsDetail.string(in: locale)
                ),
                OnboardingBulletCopy(
                    symbol: "chart.xyaxis.line",
                    title: LocalizedStringResource("History").string(in: locale),
                    detail: LocalizedStringResource.onboardingDoneHistoryDetail.string(in: locale)
                ),
                OnboardingBulletCopy(
                    symbol: "bell.badge",
                    title: LocalizedStringResource.settingsSidebarAlerts.string(in: locale),
                    detail: alertsDetail(locale: locale)
                ),
                OnboardingBulletCopy(
                    symbol: "chevron.left.forwardslash.chevron.right",
                    title: LocalizedStringResource.onboardingDoneOpenSourceTitle.string(in: locale),
                    detail: LocalizedStringResource.onboardingDoneOpenSourceDetail.string(in: locale)
                ),
            ]
        )
    }

    /// The default thresholds, read from `ThresholdPair.default`, as whole
    /// percents in the monospaced detail face.
    private static func alertsDetail(locale: Locale) -> String {
        let thresholds = ThresholdPair.default
        let warning: String = UsageFormatters.wholePercent(thresholds.warningPercent, monospaced: true, locale: locale)
        let critical: String = UsageFormatters.wholePercent(thresholds.criticalPercent, monospaced: true, locale: locale)
        return LocalizedStringResource.onboardingDoneAlertsDetail(warning, critical).string(in: locale)
    }

    var body: some View {
        OnboardingCopyStack(copy: Self.copy(hasAccounts: hasAccounts), spacing: 16, bulletSpacing: 12)
    }
}

/// A header over a list of bullets: the Welcome and Done steps.
struct OnboardingCopyStack: View {
    let copy: OnboardingStepCopy
    let spacing: CGFloat
    let bulletSpacing: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            OnboardingStepHeader(title: copy.title, subtitle: copy.subtitle)

            VStack(alignment: .leading, spacing: bulletSpacing) {
                ForEach(copy.bullets, id: \.symbol) { bullet in
                    OnboardingBullet(symbol: bullet.symbol, title: bullet.title, detail: bullet.detail)
                }
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
                .font(Theme.display(23, .bold))
                .foregroundStyle(Theme.cream)
            Text(subtitle)
                .font(Theme.mono(12))
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
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.gold)
                // 28: the widest bullet glyphs at 16pt (lock.laptopcomputer,
                // chevron.left.forwardslash.chevron.right) measure 27pt.
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Theme.display(15, .semibold))
                    .foregroundStyle(Theme.cream)
                Text(detail)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.creamDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
