import SwiftUI

/// App-level settings shown when the "General" sidebar item is selected.
/// Content moved verbatim (in behavior) from the old Settings "App" section.
struct GeneralDetailView: View {
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    @ObservedObject var appearance: AppearanceController
    @ObservedObject var settings: AppSettings
    let notificationPermission: NotificationPermission?
    let onSetSortByWeeklyReset: (Bool) -> Void
    let onSetUsageAlertsEnabled: (Bool) -> Void
    let onSetRedactNotifications: (Bool) -> Void
    let onSetShowInUseInMenuBar: (Bool) -> Void
    let onSetMenuBarWindow: (Provider, UsageWindowKind) -> Void
    let onSetMenuBarDisplaysRemaining: (Bool) -> Void
    let onOpenSetupGuide: () -> Void
    let onAllowNotifications: () -> Void
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

                LabeledContent("Open window shortcut") {
                    Text("⌥⌘U")
                        .font(Theme.mono(14, bold: true))
                        .foregroundStyle(Theme.gold)
                }
                .accessibilityIdentifier("openWindowShortcut")

                LabeledContent("Setup guide") {
                    Button("Open", action: onOpenSetupGuide)
                }
                .accessibilityIdentifier("openSetupGuideButton")

                LabeledContent("Website") {
                    Button("ration.sh") { openURL(AppLinks.website) }
                }
                .accessibilityIdentifier("openWebsiteButton")

                LabeledContent("Source code") {
                    Button("GitHub") { openURL(AppLinks.repository) }
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

                Toggle(
                    "Sort by soonest reset",
                    isOn: Binding(
                        get: { settings.sortByWeeklyReset },
                        set: { enabled in
                            onSetSortByWeeklyReset(enabled)
                        }
                    )
                )
                .accessibilityIdentifier("sortByWeeklyResetToggle")

                Text("Orders accounts within each provider; manual drag is disabled while on.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)

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

            Section(SettingsSectionTitle.menuBar) {
                Toggle(
                    "Show usage rings in the menu bar",
                    isOn: Binding(
                        get: { settings.showInUseInMenuBar },
                        set: { enabled in
                            onSetShowInUseInMenuBar(enabled)
                        }
                    )
                )
                .accessibilityIdentifier("showInUseInMenuBarToggle")

                Text("A ring per account, next to the menu bar icon, filled by the window below; accounts currently in use get a green center dot. Hover for exact values. Cursor has no rate windows and never shows.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)

                if settings.showInUseInMenuBar {
                    Picker(
                        "Display",
                        selection: Binding(
                            get: { settings.menuBarDisplaysRemaining },
                            set: { value in
                                onSetMenuBarDisplaysRemaining(value)
                            }
                        )
                    ) {
                        Text("Used %").tag(false)
                        Text("Remaining %").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("menuBarDisplayModePicker")

                    Picker(
                        "Claude window",
                        selection: Binding(
                            get: { settings.menuBarWindow(for: .claude) },
                            set: { kind in
                                onSetMenuBarWindow(.claude, kind)
                            }
                        )
                    ) {
                        Text("5-hour").tag(UsageWindowKind.fiveHour)
                        Text("Weekly").tag(UsageWindowKind.weekly)
                        Text("Fable").tag(UsageWindowKind.modelWeekly)
                    }
                    .accessibilityIdentifier("menuBarClaudeWindowPicker")

                    Text("Fable applies to Max accounts; accounts without the selected window fall back to their finest one.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)

                    LabeledContent("ChatGPT window") {
                        Text("Weekly")
                            .font(Theme.mono(14))
                            .foregroundStyle(Theme.creamDim)
                    }
                    .accessibilityIdentifier("menuBarChatGPTWindowRow")

                    Text("ChatGPT reports only a weekly limit.")
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
