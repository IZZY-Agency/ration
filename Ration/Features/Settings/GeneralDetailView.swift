import SwiftUI

/// Settings › General: the app itself (appearance, language, login, links)
/// and notifications. How gauges look lives in Display, the feature switches
/// in Features.
struct GeneralDetailView: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var appearance: AppearanceController
    @ObservedObject var settings: AppSettings
    let notificationPermission: NotificationPermission?
    let onSetUsageAlertsEnabled: (Bool) -> Void
    let onSetRedactNotifications: (Bool) -> Void
    let onOpenSetupGuide: () -> Void
    let onAllowNotifications: () -> Void
    /// Relaunch after a language change; the shared instance the app
    /// delegate reports the quit outcome to.
    var relauncher: AppRelauncher = .shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        Form {
            Section(SettingsSectionTitle.general) {
                Picker("Appearance", selection: Binding(
                    get: { appearance.mode },
                    set: { appearance.setMode($0) }
                )) {
                    ForEach(AppearanceMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearancePicker")

                LanguageSettingsRows(relauncher: relauncher)

                LabeledContent("Open window shortcut") {
                    Text(verbatim: "⌥⌘U")
                        .font(Theme.mono(14, bold: true))
                        .foregroundStyle(Theme.gold)
                }
                .accessibilityIdentifier("openWindowShortcut")

                LabeledContent("Setup guide") {
                    Button("Open", action: onOpenSetupGuide)
                }
                .accessibilityIdentifier("openSetupGuideButton")

                LabeledContent("Website") {
                    Button { openURL(AppLinks.website) } label: { Text(verbatim: "ration.sh") }
                }
                .accessibilityIdentifier("openWebsiteButton")

                LabeledContent("Source code") {
                    Button { openURL(AppLinks.repository) } label: { Text(verbatim: "GitHub") }
                }
                .accessibilityIdentifier("openRepositoryButton")

                Toggle(
                    "Launch at login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { enabled in
                            Task { await launchAtLogin.setEnabled(enabled) }
                        }
                    )
                )
                .accessibilityIdentifier("launchAtLoginToggle")

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

            Section(SettingsSectionTitle.notifications) {
                Toggle(
                    "Usage alerts",
                    isOn: Binding(
                        get: { settings.usageAlertsEnabled },
                        set: { enabled in
                            onSetUsageAlertsEnabled(enabled)
                        }
                    )
                )
                .accessibilityIdentifier("usageAlertsToggle")

                Text("Notifies you at your configured thresholds, on reset, and when an account needs attention. Set them in Alerts.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)

                if let problem = NotificationAccess.problem(
                    alertsEnabled: settings.usageAlertsEnabled,
                    permission: notificationPermission
                ) {
                    HStack(spacing: 10) {
                        Text(problem.generalNote)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.warn)
                        Spacer()
                        switch problem {
                        case .blocked:
                            Button(NotificationAccess.openSettingsTitle, action: NotificationSettingsOpener.open)
                                .accessibilityIdentifier("openNotificationSettingsButton")
                        case .needsPermission:
                            Button(NotificationAccess.allowTitle, action: onAllowNotifications)
                                .accessibilityIdentifier("allowNotificationsButton")
                        }
                    }
                }

                if settings.usageAlertsEnabled {
                    Toggle(
                        "Hide account details in notifications",
                        isOn: Binding(
                            get: { settings.redactNotifications },
                            set: { enabled in
                                onSetRedactNotifications(enabled)
                            }
                        )
                    )
                    .accessibilityIdentifier("redactNotificationsToggle")

                    Text("Keeps account labels and exact usage off the lock screen; the app still shows which account when you open it.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
        .onAppear { launchAtLogin.refresh() }
    }
}
