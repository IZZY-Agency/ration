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
    let onSetPopoverLayout: (PopoverLayout) -> Void
    var onSetFeature: (FeatureSwitch, Bool) -> Void = { _, _ in }
    /// One cell of the Show per provider grid.
    var onSetProviderShow: (ProviderShowItem, Provider, Bool) -> Void = { _, _, _ in }
    let onOpenSetupGuide: () -> Void
    let onAllowNotifications: () -> Void
    /// Relaunch after a language change; the shared instance the app
    /// delegate reports the quit outcome to.
    var relauncher: AppRelauncher = .shared
    /// "Claude plan value"; nil (snapshots, tests) hides its row.
    var tokenBurn: TokenBurnModel? = nil
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

                Picker(
                    "Layout",
                    selection: Self.layoutBinding(settings: settings, onSet: onSetPopoverLayout)
                ) {
                    ForEach(PopoverLayout.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("popoverLayoutPicker")

                Text("Focus shows the account you're on as one number, where to go next, and the rest in a line. Applies to the popover and the ⌥⌘U window.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)

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

            Section(SettingsSectionTitle.features) {
                ForEach(FeatureSwitch.allCases) { feature in
                    let features = settings.features
                    Toggle(
                        feature.title,
                        isOn: Self.featureBinding(feature, settings: settings, onSet: onSetFeature)
                    )
                    .disabled(!feature.isAvailable(in: features))
                    .accessibilityIdentifier("featureToggle-\(feature.rawValue)")

                    Text(feature.isAvailable(in: features) ? feature.summary : FeatureSwitch.switchAdviceNeedsInUseNote)
                        .font(Theme.mono(12))
                        .foregroundStyle(feature.isAvailable(in: features) ? Theme.creamDim : Theme.warn)
                }
                if let tokenBurn {
                    TokenBurnFeatureRow(model: tokenBurn)
                }
                ProviderShowGrid(settings: settings, onSet: onSetProviderShow)
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

                Text("A ring per account, filled by the window below, in place of the menu bar icon (it comes back when nothing shows); accounts currently in use get a green center dot. API accounts with a monthly budget show a square. Hover for exact values. Cursor has no rate windows and never shows.")
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
                        Text(verbatim: SettingsCopy.windowLabel(.fiveHour)).tag(UsageWindowKind.fiveHour)
                        Text(verbatim: SettingsCopy.windowLabel(.weekly)).tag(UsageWindowKind.weekly)
                        Text(verbatim: SettingsCopy.windowLabel(.modelWeekly)).tag(UsageWindowKind.modelWeekly)
                    }
                    .accessibilityIdentifier("menuBarClaudeWindowPicker")

                    Text("Fable applies to Max accounts; accounts without the selected window fall back to their finest one.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)

                    LabeledContent("ChatGPT window") {
                        Text(verbatim: SettingsCopy.windowLabel(.weekly))
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

    /// One Features row's toggle: reads the published switch, writes only
    /// through the callback (which persists via `AppModel`).
    static func featureBinding(
        _ feature: FeatureSwitch,
        settings: AppSettings,
        onSet: @escaping (FeatureSwitch, Bool) -> Void
    ) -> Binding<Bool> {
        Binding(
            get: { feature.isOn(in: settings.features) },
            set: { onSet(feature, $0) }
        )
    }

    /// The Layout picker's selection: reads the published setting, writes
    /// only through the callback (which persists via `AppModel`).
    static func layoutBinding(
        settings: AppSettings,
        onSet: @escaping (PopoverLayout) -> Void
    ) -> Binding<PopoverLayout> {
        Binding(
            get: { settings.popoverLayout },
            set: { layout in
                onSet(layout)
            }
        )
    }
}

/// Settings → General → Features → Show per provider: a row per item, a column per provider, a checkbox where the
/// provider has that item and a dash where it has none.
struct ProviderShowGrid: View {
    @ObservedObject var settings: AppSettings
    let onSet: (ProviderShowItem, Provider, Bool) -> Void

    static let columnWidth: CGFloat = 76

    var body: some View {
        let columns = ProviderShowItem.columns
        let show = settings.providerShowSwitches
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                Text(LocalizedStringResource.providerShowTitle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                ForEach(columns) { provider in
                    Text(verbatim: provider.displayName)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.creamDim)
                        .frame(width: Self.columnWidth)
                }
            }
            ForEach(ProviderShowItem.allCases, id: \.self) { item in
                HStack(spacing: 0) {
                    Text(item.title())
                        .frame(maxWidth: .infinity, alignment: .leading)
                    ForEach(columns) { provider in
                        cell(item, provider, show: show)
                            .frame(width: Self.columnWidth)
                    }
                }
            }
            Text(LocalizedStringResource.providerShowNote)
                .font(Theme.mono(12))
                .foregroundStyle(Theme.creamDim)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func cell(_ item: ProviderShowItem, _ provider: Provider, show: ProviderShow) -> some View {
        if item.applies(to: provider) {
            Toggle(isOn: Binding(
                get: { show.shows(item, for: provider) },
                set: { onSet(item, provider, $0) }
            )) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(Text(LocalizedStringResource.providerShowCellLabel(item.title(), provider.displayName)))
                .accessibilityIdentifier("providerShow-\(provider.rawValue)-\(item.rawValue)")
        } else {
            Text(verbatim: "—")
                .foregroundStyle(Theme.creamFaint)
                .accessibilityLabel(Text(LocalizedStringResource.providerShowNone(item.title(), provider.displayName)))
        }
    }
}
