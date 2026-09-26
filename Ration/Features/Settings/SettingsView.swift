import SwiftUI

struct SettingsView: View {
    /// The sidebar's ideal width plus the 450 pt of detail pane the window
    /// had before the sidebar grew for the +2 pt type (660 − 210).
    static let minimumWindowWidth: CGFloat = 720

    @ObservedObject var model: AppModel
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    /// Passed through to `GeneralDetailView` (which observes it) as an init
    /// parameter, like every other dependency here — no EnvironmentObject, so
    /// a missing injection is a compile error rather than a runtime crash.
    let appearance: AppearanceController
    @ObservedObject var history: UsageHistoryStore
    let onAddAccount: () -> Void
    let onOpenSignIn: (UUID) -> Void
    let onOpenSetupGuide: () -> Void

    @State private var selection: SettingsSelection?
    @State private var accountToRemove: AccountRecord?
    /// `AppSettings` is its own `ObservableObject`, which `model` never
    /// republishes — mirrored here so a switch flipped in General redraws the
    /// sidebar's IN USE pills and the account pane at once.
    @State private var features: FeatureSwitches = .allOn
    @State private var errorMessage: String?

    /// Computed from the non-paused subset only: a paused account can have
    /// recent history for up to the lookback window, and must not be able to
    /// hold the provider's single IN USE marker and deprive the genuinely
    /// active account of it. Paused accounts still appear in the sidebar list
    /// (`model.presentations`, unfiltered) — only this detection input is
    /// restricted.
    private var activeUsage: [UUID: ActiveUsage] {
        // In-use detection off → no IN USE pill in the sidebar or account pane.
        guard features.inUse else { return [:] }
        return ActiveUsageMap.compute(
            accounts: AccountVisibility.visible(model.accounts),
            history: history,
            now: .now
        )
    }

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(
                presentations: model.presentations,
                activeUsage: activeUsage,
                selection: $selection,
                canReorder: !model.settings.sortByWeeklyReset,
                onMove: move,
                onAddAccount: onAddAccount
            )
            .navigationSplitViewColumnWidth(
                min: SettingsSidebar.minColumnWidth,
                ideal: SettingsSidebar.idealColumnWidth,
                max: SettingsSidebar.maxColumnWidth
            )
        } detail: {
            detail
                .overlay(alignment: .bottom) { errorBanner }
        }
        .tint(Theme.gold)
        .background(Theme.ink)
        .frame(minWidth: Self.minimumWindowWidth, minHeight: 470)
        .task { ensureSelection() }
        .onReceive(model.settings.featuresPublisher) { features = $0 }
        .onChange(of: model.accounts.map(\.id)) { _, _ in ensureSelection() }
        .alert(
            "Remove account?",
            isPresented: Binding(
                get: { accountToRemove != nil },
                set: { if !$0 { accountToRemove = nil } }
            ),
            presenting: accountToRemove
        ) { account in
            Button("Remove \(account.label)", role: .destructive) {
                perform(request: {
                    let task = try model.requestRemoveAccount(id: account.id)
                    return Task { try await task.value; accountToRemove = nil }
                })
            }
            Button("Cancel", role: .cancel) { accountToRemove = nil }
        } message: { _ in
            Text("This removes its saved limits and isolated browser session from this Mac.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection {
        case let .account(id):
            if let presentation = model.presentations.first(where: { $0.account.id == id }) {
                AccountDetailView(
                    presentation: presentation,
                    activeUsage: activeUsage[id],
                    features: features,
                    // Awaited so `LabelAutosave` can serialize saves, retry a
                    // busy account and keep a failed edit. It does not clear
                    // the banner per attempt: busy retries would wipe other
                    // actions' errors every second. It reports `nil` once a
                    // save succeeds after its own error.
                    onRename: { label in
                        try await model.renameAccount(id: id, label: label)
                    },
                    onRenameError: { errorMessage = $0?.localizedDescription },
                    pendingEdits: model.pendingEdits,
                    onReauthenticate: { beginReauthentication(id) },
                    onRemove: { accountToRemove = presentation.account },
                    onSetAutoStart: { enabled in
                        perform(request: { try model.requestSetAutoStart(accountID: id, enabled: enabled) })
                    },
                    onSetBillingRenewalDay: { day in
                        perform(request: { try model.requestSetBillingRenewalDay(accountID: id, day: day) })
                    },
                    onSetPlan: { plan in
                        perform(request: { try model.requestSetPlan(accountID: id, plan: plan) })
                    },
                    onSetPaused: { paused in
                        perform(request: { try model.requestSetPaused(accountID: id, paused: paused) })
                    },
                    onDebugSend: {
                        #if DEBUG
                        Task { await model.debugSendKeepAlive(accountID: id) }
                        #endif
                    }
                )
                .id(id)
            } else {
                placeholder
            }
        case .warmUp:
            WarmUpDetailView(
                settings: model.settings,
                // Warm-up switched off globally → nothing warms up, so quiet
                // hours suppress no warm-up either.
                autoStartEnabledCount: features.warmUp
                    ? AutoStartPolicy.effectiveAutoStartCount(model.accounts)
                    : 0,
                pendingEdits: model.pendingEdits,
                // Awaited (not `perform`-and-forget) so the pane can tell a
                // successful save from a failed one and keep the edit.
                onSetQuietHours: { cells in
                    errorMessage = nil
                    try await model.setQuietHours(cells)
                },
                onAddHoliday: { holiday in
                    errorMessage = nil
                    try await model.addHoliday(holiday)
                },
                onSetHolidayLabel: { id, label in
                    errorMessage = nil
                    try await model.setHolidayLabel(id: id, label)
                },
                onSetHolidayStart: { id, start in
                    errorMessage = nil
                    try await model.setHolidayStart(id: id, start)
                },
                onSetHolidayEnd: { id, end in
                    errorMessage = nil
                    try await model.setHolidayEnd(id: id, end)
                },
                onRemoveHoliday: { id in
                    errorMessage = nil
                    try await model.removeHoliday(id: id)
                },
                onError: { errorMessage = $0.localizedDescription }
            )
        case .general:
            GeneralDetailView(
                launchAtLogin: launchAtLogin,
                appearance: appearance,
                settings: model.settings,
                notificationPermission: model.notificationPermission,
                onSetSortByWeeklyReset: { enabled in
                    perform { try await model.setSortByWeeklyReset(enabled) }
                },
                onSetUsageAlertsEnabled: { enabled in
                    perform(request: { model.requestSetUsageAlerts(enabled) })
                },
                onSetRedactNotifications: { enabled in
                    perform { try await model.setRedactNotifications(enabled) }
                },
                onSetShowInUseInMenuBar: { enabled in
                    perform { try await model.setShowInUseInMenuBar(enabled) }
                },
                onSetMenuBarWindow: { provider, kind in
                    perform { try await model.setMenuBarWindow(kind, for: provider) }
                },
                onSetMenuBarDisplaysRemaining: { enabled in
                    perform { try await model.setMenuBarDisplaysRemaining(enabled) }
                },
                onSetPopoverLayout: { layout in
                    perform { try await model.setPopoverLayout(layout) }
                },
                onSetFeature: { feature, enabled in
                    perform { try await model.setFeature(feature, enabled: enabled) }
                },
                onOpenSetupGuide: onOpenSetupGuide,
                onAllowNotifications: { model.requestNotificationPermission() }
            )
        case .alerts:
            AlertsDetailView(
                settings: model.settings,
                providers: model.accounts.map(\.provider),
                notificationPermission: model.notificationPermission,
                onAllowNotifications: { model.requestNotificationPermission() },
                onSetWarningPercent: { value, provider, window in
                    try await model.setWarningPercent(value, provider: provider, window: window)
                },
                onSetCriticalPercent: { value, provider, window in
                    try await model.setCriticalPercent(value, provider: provider, window: window)
                },
                onSetSpendWarningCents: { value in
                    try await model.setSpendWarningCents(value)
                },
                onSetSpendCriticalCents: { value in
                    try await model.setSpendCriticalCents(value)
                },
                onSetDropEnabled: { enabled, key in
                    try await model.setDropEnabled(enabled, forKey: key)
                },
                onSetNotificationEnabled: { enabled, key in
                    try await model.setNotificationEnabled(enabled, forKey: key)
                },
                onSetResetLeadDays: { days, provider in
                    try await model.setResetExpiryLeadDays(days, provider: provider)
                },
                onError: { errorMessage = $0.localizedDescription }
            )
        case nil:
            placeholder
        }
    }

    @ViewBuilder
    private var placeholder: some View {
        if model.accounts.isEmpty {
            ContentUnavailableView {
                Label("No accounts", systemImage: "person.crop.circle.badge.plus")
            } description: {
                Text("Add an account to see real limits.")
            } actions: {
                Button("Add Account", action: onAddAccount)
            }
            .background(Theme.ink)
        } else {
            ContentUnavailableView(
                "Select an account",
                systemImage: "sidebar.left"
            )
            .background(Theme.ink)
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let errorMessage {
            Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.crit)
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.panel)
        }
    }

    private func ensureSelection() {
        selection = SettingsSelection.normalized(selection, accounts: model.accounts)
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        guard let source = offsets.first else { return }
        let accounts = model.accounts
        guard source < accounts.count else { return }
        let target = destination > source ? destination - 1 : destination
        let id = accounts[source].id
        perform { try await model.moveAccount(id: id, to: target) }
    }

    private func beginReauthentication(_ accountID: UUID) {
        do {
            let sessionID = try model.beginReauthentication(accountID: accountID)
            onOpenSignIn(sessionID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        errorMessage = nil
        Task {
            do {
                try await operation()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Runs a synchronous intent-claiming request in the caller's (MainActor,
    /// non-async) context — i.e. within the SwiftUI action, BEFORE any Task —
    /// then awaits the already-started Task it returns only to surface errors.
    /// The claim is therefore recorded at the tap, visible to concurrently
    /// suspended background logic, instead of whenever an unstructured Task is
    /// scheduled.
    private func perform(request: () throws -> Task<Void, Error>) {
        errorMessage = nil
        let task: Task<Void, Error>
        do {
            task = try request()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        Task {
            do { try await task.value } catch { errorMessage = error.localizedDescription }
        }
    }
}
