import SwiftUI

@MainActor
final class RationApplicationDelegate: NSObject, NSApplicationDelegate {
    private(set) var menuBarController: MenuBarController?
    private var didFinishLaunching = false
    weak var model: AppModel?
    weak var launchAtLogin: LaunchAtLoginController?
    private var hotKeyRegistrar: (any GlobalHotKeyRegistering)?
    /// Dock + ⌘-Tab presence while any Ration window is open — see `DockPresence`.
    private let dockPresence = DockPresenceController()
    /// App activation / any window (the popover included) becoming key —
    /// the moments a user may be back from changing the notification
    /// permission in System Settings. See
    /// `AppModel.recheckNotificationAuthorization()`.
    private var authorizationRecheckObservers: [NSObjectProtocol] = []
    /// The System/Light/Dark preference. Read synchronously from UserDefaults
    /// at construction so it can be applied before any window exists.
    let appearance = AppearanceController()
    /// Outstanding `.terminateLater` decisions. A COUNT, not a flag: quits can
    /// overlap, and one aborted quit must not declare the app safe while
    /// another decision is still pending.
    private var outstandingTerminationDecisions = 0

    private var isTerminating: Bool { outstandingTerminationDecisions > 0 }
    /// Relaunch after a language change. It only observes the quit outcome:
    /// a refused quit clears its intent, a proceeding one launches the new
    /// instance from `applicationWillTerminate`.
    var relauncher: AppRelauncher = .shared
    /// Sends a `.terminateLater` decision to AppKit. A seam so tests can run
    /// the real deferred path without replying to the test host's `NSApp`.
    var replyToTermination: @MainActor (NSApplication, Bool) -> Void = { sender, canTerminate in
        sender.reply(toApplicationShouldTerminate: canTerminate)
    }
    /// The open `.terminateLater` decision's preparation (flushing Settings
    /// edits, cancelling sign-ins, profile cleanup); exposed so tests can
    /// await it.
    private(set) var terminationPreparation: Task<Void, Never>?
    /// A relaunched instance holds its menu bar (status item, hot keys) until
    /// the previous instance has exited — see `PreviousInstanceWaiter`.
    private var isHeldForPreviousInstance = false

    /// Test seam: whether a first-run wizard is still owed. The delegate keeps
    /// no copy of this — `AppModel` is the single owner, which is what stops a
    /// dismissal and a pending delivery from disagreeing.
    var isOnboardingOwed: Bool { model?.isOnboardingOwed ?? false }

    func configure(
        model: AppModel,
        launchAtLogin: LaunchAtLoginController,
        hotKeyRegistrar: any GlobalHotKeyRegistering = CarbonHotKeyRegistrar()
    ) {
        self.model = model
        self.launchAtLogin = launchAtLogin
        self.hotKeyRegistrar = hotKeyRegistrar
        startMenuBarIfReady()
    }

    /// Opens the first-run wizard if this launch owes one.
    ///
    /// Called after `AppModel.start()`, since the decision is recorded during
    /// `load()`. Whichever of startup and `applicationDidFinishLaunching` lands
    /// second wins: if the controller is not up yet this is a no-op, and
    /// `startMenuBarIfReady()` delivers instead. Safe to call repeatedly —
    /// `showOnboarding()` focuses an already-open wizard.
    func presentOnboardingIfNeeded() {
        deliverOnboardingIfPossible()
    }

    /// Runs the production consequence of one `.terminateLater` decision being
    /// resolved. Both the real reply path and the test seam call THIS, so a
    /// test cannot pass while the production path is broken.
    private func terminationDecisionResolved(canTerminate: Bool) {
        // A `true` reply resumes termination; the count is moot from there.
        guard !canTerminate else {
            relauncher.terminationWasApproved()
            return
        }
        outstandingTerminationDecisions = max(
            0,
            outstandingTerminationDecisions - 1
        )
        relauncher.terminationWasCancelled()
        deliverOnboardingIfPossible()
    }

    /// Called before `configure` when this launch must wait for a previous
    /// instance to exit; `releaseStartup()` lifts it.
    func holdStartupForPreviousInstance() {
        isHeldForPreviousInstance = true
    }

    func releaseStartup() {
        guard isHeldForPreviousInstance else { return }
        isHeldForPreviousInstance = false
        startMenuBarIfReady()
    }

    /// Test seam: resolve an outstanding decision. Delegates to the production
    /// path above rather than reimplementing it.
    func resolveTerminationForTesting(canTerminate: Bool) {
        terminationDecisionResolved(canTerminate: canTerminate)
    }

    /// Shows the wizard once nothing stands in the way. Idempotent — a second
    /// call while it is open merely focuses it — and safe to call from every
    /// place that can remove an obstacle: startup finishing, the controller
    /// being created, and a quit being aborted.
    ///
    /// `AppModel.isOnboardingOwed` is the sole source of truth. Reading it here
    /// is NOT the delivery-time re-derivation that caused an earlier defect:
    /// that re-derived the answer from the live account count, which goes
    /// transiently non-zero mid-commit. This flag is decided once at load and
    /// cleared only by an actual dismissal, so it cannot be transiently wrong —
    /// and reading it is what makes a manually opened and closed wizard consume
    /// the owed presentation instead of it reappearing after an aborted quit.
    private func deliverOnboardingIfPossible() {
        guard
            let model,
            model.isOnboardingOwed,
            !isTerminating,
            let menuBarController
        else {
            return
        }
        menuBarController.showOnboarding()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        didFinishLaunching = true
        // Appearance comes from UserDefaults so it is known synchronously,
        // before MenuBarController builds any window.
        appearance.apply()
        dockPresence.start()
        startNotificationAuthorizationRechecks()
        startMenuBarIfReady()
    }

    private func startNotificationAuthorizationRechecks() {
        guard authorizationRecheckObservers.isEmpty else { return }
        let names: [Notification.Name] = [
            NSApplication.didBecomeActiveNotification,
            NSWindow.didBecomeKeyNotification
        ]
        authorizationRecheckObservers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Discard the returned Task explicitly: Xcode 26.6's Swift
                // otherwise infers the closure's result type from it and
                // fails to match `assumeIsolated`'s Void body.
                MainActor.assumeIsolated {
                    _ = self?.model?.recheckNotificationAuthorization()
                }
            }
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        outstandingTerminationDecisions += 1
        relauncher.terminationWasRequested()
        guard let model, model.requiresTerminationPreparation else {
            // Terminating now; the count is moot from here.
            relauncher.terminationWasApproved()
            return .terminateNow
        }

        // Runs on the main actor while AppKit waits for the reply: AppKit
        // spins the main run loop in its modal-panel mode, and main-actor
        // tasks and sleeps run there (probed on macOS 27.2). EXCEPT when
        // `terminate()` itself was called from inside a main-queue block
        // (`DispatchQueue.main.async`, a main-actor Task): the main queue does
        // not drain re-entrantly, this Task never starts and the app hangs.
        // So every quit must start from an event or a run-loop block — see
        // `HotKeyCallbackContext.fire()`.
        terminationPreparation = Task { @MainActor in
            let canTerminate = await model.prepareForTermination()
            // Replying `false` ABORTS the quit and the app keeps running, so
            // this decision stops counting — and if it was the last one
            // outstanding, any wizard owed since before the quit is delivered.
            // Otherwise a first launch that finished loading mid-quit would
            // lose its wizard for the rest of the session.
            terminationDecisionResolved(canTerminate: canTerminate)
            replyToTermination(sender, canTerminate)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        let windows = DockPresence.realWindows()
        switch DockPresence.reopenAction(
            hasVisibleWindows: flag,
            hasMiniaturizedWindow: windows.contains(where: \.isMiniaturized)
        ) {
        case .bringExistingForward:
            return true
        case .deminiaturize:
            windows.first(where: \.isMiniaturized)?.deminiaturize(nil)
            return false
        case .showFallback:
            menuBarController?.showFallbackWindow()
            return false
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBarController?.stop()
        menuBarController = nil
        model?.stop()
        // Last: the quit is certainly proceeding, and this instance has let go
        // of its status item and timers before the new one starts.
        relauncher.terminationWillProceed()
    }

    private func startMenuBarIfReady() {
        guard
            didFinishLaunching,
            !isHeldForPreviousInstance,
            menuBarController == nil,
            let model,
            let launchAtLogin
        else {
            return
        }

        let controller = MenuBarController(
            model: model,
            launchAtLogin: launchAtLogin,
            appearance: appearance,
            hotKeyRegistrar: hotKeyRegistrar ?? CarbonHotKeyRegistrar()
        )
        menuBarController = controller
        controller.start()

        // Stays owed if a quit is in progress; aborting that quit delivers it.
        deliverOnboardingIfPossible()
    }
}

@main
struct RationApp: App {
    @NSApplicationDelegateAdaptor(RationApplicationDelegate.self)
    private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var launchAtLogin: LaunchAtLoginController
    private let isUITesting: Bool

    init() {
        // Before anything can quit: a quit made while another is being
        // decided joins it instead of skipping its saves and cleanup.
        TerminationGate.install()
        AppFonts.register()
        let arguments = ProcessInfo.processInfo.arguments
        let isUITesting = arguments.contains("--ui-testing")
        let probeRuntime = ProviderContractProbeRuntime(arguments: arguments)
        let captureStateDirectory = FileManager.default.temporaryDirectory
            .appending(
                path: "ration-contract-capture-state",
                directoryHint: .isDirectory
            )
        // One Claude stack: the adapters and the auto-start sender share a
        // resolver so the irreversible send is bound to the org the
        // triggering usage fetch actually used.
        let liveStack = LiveProviderAdapters.live()
        let model = AppModel.live(
            adapters: probeRuntime.isEnabled
                ? probeRuntime.adapters
                : liveStack.adapters,
            messageSender: liveStack.claudeMessageSender,
            contractRecorder: probeRuntime.recorder,
            baseDirectory: probeRuntime.isEnabled ? captureStateDirectory : nil
        )
        if let startupError = probeRuntime.startupError {
            model.errorMessage = startupError
        }
        let launchAtLogin = LaunchAtLoginController()
        self.isUITesting = isUITesting
        _model = StateObject(wrappedValue: model)
        _launchAtLogin = StateObject(wrappedValue: launchAtLogin)
        let delegate = appDelegate
        // A relaunch (language change) names the instance it replaces. Nothing
        // above has read a store or touched WebKit; the start below waits.
        let awaitedPID: pid_t? = isUITesting
            ? nil
            : RelaunchHandoff(defaults: .standard).consumeAwaitedPID(
                arguments: arguments,
                ownPID: ProcessInfo.processInfo.processIdentifier,
                now: Date()
            )
        if awaitedPID != nil {
            delegate.holdStartupForPreviousInstance()
        }
        delegate.configure(
            model: model,
            launchAtLogin: launchAtLogin
        )

        if !isUITesting {
            Task { @MainActor in
                if let awaitedPID {
                    _ = await PreviousInstanceWaiter.live().waitForExit(of: awaitedPID)
                    delegate.releaseStartup()
                }
                await model.start()
                // Only now can the wizard's predicate be answered: `start()`
                // is what loads `AppSettings`.
                delegate.presentOnboardingIfNeeded()
            }
        }
    }

    var body: some Scene {
        // The brand name, never translated.
        Window(Text(verbatim: "Ration"), id: "ui-testing") {
            menuContent
        }
        .defaultSize(width: 400, height: 470)
        .defaultLaunchBehavior(
            isUITesting ? .presented : .suppressed
        )
        .restorationBehavior(.disabled)
        .commands {
            // Wire the standard macOS ⌘, Settings shortcut. As an accessory
            // (LSUIElement) app, the menu bar — and this key equivalent — is
            // active whenever any Ration window is key.
            CommandGroup(replacing: .appSettings) {
                SettingsMenuCommand()
            }
        }

        Window("Add Account", id: "add-account") {
            AddAccountWindowContent(model: model)
        }
        .defaultSize(width: 420, height: 530)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        WindowGroup("Sign In", id: "sign-in", for: UUID.self) { sessionID in
            SignInWindowContent(model: model, sessionID: sessionID.wrappedValue)
        }
        .defaultSize(width: 760, height: 680)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("Settings", id: "settings") {
            SettingsWindowContent(
                model: model,
                launchAtLogin: launchAtLogin,
                appearance: appDelegate.appearance,
                onOpenSetupGuide: openSetupGuide
            )
        }
        .defaultSize(width: SettingsView.minimumWindowWidth, height: 564)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Window("About Ration", id: "about") {
            AboutWindowContent()
        }
        .defaultSize(width: 360, height: 286)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .windowResizability(.contentSize)

        Window("History", id: "history") {
            HistoryWindowContent(model: model)
        }
        .defaultSize(width: 720, height: 520)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }

    private var menuContent: some View {
        MenuBarSceneContent(model: model, onOpenSetupGuide: openSetupGuide)
    }

    /// The Setup Guide has exactly ONE owner: `MenuBarController`. The SwiftUI
    /// scenes route here rather than declaring their own `Window`, so pressing
    /// ⌘, while the auto-presented wizard is up focuses that wizard instead of
    /// spawning a rival copy with its own step state and sign-in sessions.
    /// Sole AppKit ownership also means completion is recorded by
    /// `observeClose` — a documented `NSWindowDelegate` callback — rather than
    /// by SwiftUI's `.onDisappear`, whose timing for a `Window` traffic-light
    /// close Apple does not guarantee.
    ///
    /// The delegate is captured from the adaptor rather than looked up via
    /// `NSApp.delegate`, which does NOT vend the adaptor instance back (a cast
    /// to `RationApplicationDelegate` returns nil — verified at runtime).
    private var openSetupGuide: () -> Void {
        let delegate = appDelegate
        return {
            NSApplication.shared.activate()
            delegate.menuBarController?.showOnboarding()
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var model: AppModel
    // Observed directly (not just reached via `model.history`) so a
    // background refresh that records a new burn — which publishes on
    // `UsageHistoryStore.rawSeries`, not on `AppModel` — invalidates this
    // view and recomputes the active-map immediately, even while the
    // popover is already open.
    @ObservedObject var history: UsageHistoryStore
    @ObservedObject var pinSnapshot: AccountPinSnapshot
    // `AppSettings` is its own `ObservableObject` (see the same trap
    // documented at `MenuBarController.updateGauges`'s subscription):
    // `model`'s own `objectWillChange` never fires for a settings-only
    // change like `resetExpiryLeadDays`, so `resetLeadDaysByProvider` below
    // must be computed from an observed `settings`, not `model.settings`.
    @ObservedObject var settings: AppSettings
    let onAddAccount: () -> Void
    let onSettings: () -> Void
    let onAbout: () -> Void
    let onHistory: () -> Void
    let onOpenSignIn: (UUID) -> Void
    let onOpenSetupGuide: () -> Void
    /// The attention drop's on-screen state, for the popover's keyboard route
    /// to its ✕ — owned by whoever owns the surface (`MenuBarController`, or
    /// the UI-testing scene's own instance).
    @ObservedObject var attentionPresence: AttentionDropPresence
    var onDismissAttentionDrop: () -> Void = {}
    /// The footer's Refresh / Quit. The menu-bar controller passes its own, so
    /// its popover hotkeys run the very same closures.
    var onRefresh: (() -> Void)?
    var onQuit: (() -> Void)?
    /// Opens Settings on one pane — the header's STALE click, on the account
    /// to fix. nil (the SwiftUI scene) falls back to plain `onSettings`.
    var onSettingsSelecting: ((SettingsSelection) -> Void)?

    var body: some View {
        MenuBarView(
            presentations: AccountVisibility.visible(model.presentations),
            isRefreshing: model.isRefreshing,
            profileCleanupBanner: model.profileCleanupBanner,
            signInQuitPauseBanner: model.signInQuitPauseBanner,
            errorMessage: model.errorMessage,
            warmUpBanner: { model.warmUpBanner(at: $0) },
            // In-use detection off → no IN USE pill, frame or tint.
            activeAccounts: settings.featureInUseEnabled
                ? ActiveUsageMap.compute(accounts: model.visibleAccounts, history: history, now: .now)
                : [:],
            showsResetCredits: settings.featureResetsEnabled,
            pausedCount: model.accounts.count - model.visibleAccounts.count,
            onOpen: {
                Task {
                    await model.refreshWhenOpened()
                }
            },
            onAddAccount: onAddAccount,
            onRefresh: onRefresh ?? {
                Task {
                    await model.refreshAll()
                }
            },
            onSettings: onSettings,
            onAbout: onAbout,
            onHistory: onHistory,
            onRetryProfileCleanup: {
                Task {
                    await model.retryProfileCleanup()
                }
            },
            onQuit: onQuit ?? {
                AppRelauncher.shared.quitWithoutRelaunch()
            },
            onReauthenticate: { accountID in
                do {
                    let sessionID = try model.beginReauthentication(
                        accountID: accountID
                    )
                    onOpenSignIn(sessionID)
                } catch {
                    model.errorMessage = error.localizedDescription
                }
            },
            samples: { accountID, kind in
                history.rawSamples(accountID: accountID, kind: kind)
            },
            projection: { accountID, kind in
                let series = history.rawSeries[accountID]?[kind]
                    ?? UsageWindowSeries(kind: kind)
                let isCurrent = model.presentations
                    .first { $0.id == accountID }?.state == .current
                return BurnRateProjector.projectedExhaustion(
                    for: series,
                    now: .now,
                    isAccountCurrent: isCurrent,
                    refreshInterval: 300
                )
            },
            orderingPinByProvider: pinSnapshot.orderingPinByProvider,
            resetLeadDaysByProvider: Dictionary(
                uniqueKeysWithValues: Provider.allCases.map {
                    ($0, settings.data.resetExpiryLeadDays(provider: $0))
                }
            ),
            onOpenSetupGuide: onOpenSetupGuide,
            notificationProblem: NotificationAccess.problem(
                alertsEnabled: settings.usageAlertsEnabled,
                permission: model.notificationPermission
            ),
            onOpenNotificationSettings: NotificationSettingsOpener.open,
            onAllowNotifications: { model.requestNotificationPermission() },
            attentionDropShowing: attentionPresence.isShowing,
            onDismissAttentionDrop: onDismissAttentionDrop,
            switchAdvice: model.switchAdvice,
            layout: settings.popoverLayout,
            focusModel: { [pinned = pinSnapshot.focusHeroID] in
                model.focusModel(now: $0, pinnedHeroID: pinned)
            },
            onSetLayout: { layout in
                Task { await Self.setLayout(layout, model: model) }
            },
            onShowFocusHero: { [pinSnapshot] id in pinSnapshot.pinFocusHero(id) },
            onFreshnessAction: { target in
                performFreshnessAction(target)
            }
        )
        .tint(Theme.gold)
    }

    /// The header's STALE / OFFLINE click: the account to fix in Settings,
    /// or the Refresh button's own path.
    private func performFreshnessAction(_ target: FreshnessHelp.Target) {
        switch target {
        case let .account(id):
            if let onSettingsSelecting {
                onSettingsSelecting(.account(id))
            } else {
                onSettings()
            }
        case .refreshAll:
            if let onRefresh {
                onRefresh()
                return
            }
            Task {
                await model.refreshAll(reason: .manual)
            }
        }
    }

    /// The header's STANDARD | FOCUS switch: the same persisted setting the
    /// Settings picker writes; a failure surfaces as the popover's error row.
    static func setLayout(_ layout: PopoverLayout, model: AppModel) async {
        guard model.settings.popoverLayout != layout else { return }
        do {
            try await model.setPopoverLayout(layout)
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }
}

private struct MenuBarSceneContent: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel
    let onOpenSetupGuide: () -> Void
    // This SwiftUI-scene window is its own presentation surface (used only
    // under --ui-testing), so it gets its own snapshot rather than sharing
    // one of MenuBarController's — same "one snapshot per surface" rule as
    // the popover and the ⌥⌘U fallback window.
    //
    // The retained snapshot is one-shot, but not because `init` below runs
    // only once — `MenuBarSceneContent` is constructed on every
    // `RationApp.body` evaluation (i.e. on every `AppModel` publish),
    // since `Window`'s content builder is non-escaping. It is one-shot
    // because `@StateObject` only *invokes* the `AccountPinSnapshot.captured`
    // autoclosure passed to it below the first time it materializes storage
    // for this view's identity; every later `init` still constructs the
    // autoclosure value but SwiftUI never calls it, so the originally
    // captured instance is retained untouched for the life of the view. This
    // view exists solely to host UITests under --ui-testing, and no UITest
    // asserts pinning/ordering, so a permanently-stale-after-first-
    // materialization snapshot is an acceptable trade. Do NOT "fix" this by
    // adding `.onAppear`: SwiftUI documents `.onAppear` timing as view-type
    // dependent and gives no guarantee that closing and reopening a `Window`
    // scene recreates the view or re-fires it — relying on that is the exact
    // defect that sank two earlier revisions of this design (see
    // AccountPinSnapshot's doc comment). If this surface ever becomes
    // user-facing, give it a real capture-on-reopen path instead, mirroring
    // MenuBarController.showFallbackWindow's use of
    // `AccountPinSnapshot.shouldCapture`.
    @StateObject private var pinSnapshot: AccountPinSnapshot
    /// This surface has no drop, so its presence never turns on — but it is
    /// one retained instance, not a fresh object per `init`.
    @StateObject private var attentionPresence = AttentionDropPresence()

    init(model: AppModel, onOpenSetupGuide: @escaping () -> Void) {
        self.model = model
        self.onOpenSetupGuide = onOpenSetupGuide
        _pinSnapshot = StateObject(
            wrappedValue: AccountPinSnapshot.captured(
                accounts: model.visibleAccounts,
                history: model.history,
                now: .now,
                inUseEnabled: model.settings.featureInUseEnabled
            )
        )
    }

    var body: some View {
        MenuBarContent(
            model: model,
            history: model.history,
            pinSnapshot: pinSnapshot,
            settings: model.settings,
            onAddAccount: {
                NSApplication.shared.activate()
                openWindow(id: "add-account")
            },
            onSettings: {
                NSApplication.shared.activate()
                openWindow(id: "settings")
            },
            onAbout: {
                NSApplication.shared.activate()
                openWindow(id: "about")
            },
            onHistory: {
                NSApplication.shared.activate()
                openWindow(id: "history")
            },
            onOpenSignIn: { sessionID in
                NSApplication.shared.activate()
                openWindow(id: "sign-in", value: sessionID)
            },
            onOpenSetupGuide: onOpenSetupGuide,
            attentionPresence: attentionPresence
        )
    }
}

private struct AddAccountWindowContent: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var model: AppModel

    var body: some View {
        AddAccountView(
            model: model,
            onOpenSignIn: { sessionID in
                NSApplication.shared.activate()
                openWindow(id: "sign-in", value: sessionID)
            },
            onDismiss: {
                dismiss()
            }
        )
    }
}

private struct SettingsWindowContent: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    @ObservedObject var launchAtLogin: LaunchAtLoginController
    let appearance: AppearanceController
    let onOpenSetupGuide: () -> Void

    var body: some View {
        SettingsView(
            model: model,
            launchAtLogin: launchAtLogin,
            appearance: appearance,
            history: model.history,
            onAddAccount: {
                NSApplication.shared.activate()
                openWindow(id: "add-account")
            },
            onOpenSignIn: { sessionID in
                NSApplication.shared.activate()
                openWindow(id: "sign-in", value: sessionID)
            },
            onOpenSetupGuide: onOpenSetupGuide
        )
        .onExitCommand { dismiss() }
    }
}

/// Wraps the About window so Escape dismisses it, matching Settings.
private struct AboutWindowContent: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        AboutView()
            .onExitCommand { dismiss() }
    }
}

/// The Setup Guide has exactly ONE owner: `MenuBarController`. The SwiftUI
/// scenes route here rather than opening a second `Window`, so pressing ⌘,
/// while the auto-presented wizard is up focuses that wizard instead of
/// spawning a rival copy with its own step state and its own sign-in sessions.
/// Keeping the AppKit path sole owner also means completion is recorded by
/// `observeClose` — a documented `NSWindowDelegate` callback — rather than by
/// SwiftUI's `.onDisappear`, whose timing for a `Window` traffic-light close is
/// not guaranteed.
/// Wraps the History window so Escape dismisses it, matching About/Settings.
private struct HistoryWindowContent: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel

    var body: some View {
        HistoryView(model: model)
            .onExitCommand { dismiss() }
    }
}

/// The "Settings…" app-menu command, wired to ⌘,. Lives in a view so it can
/// read `openWindow` from the environment inside the command builder.
private struct SettingsMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            NSApplication.shared.activate()
            openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

private struct SignInWindowContent: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: AppModel
    let sessionID: UUID?

    var body: some View {
        if
            let sessionID,
            let session = model.signInSession(for: sessionID)
        {
            SignInSessionView(
                model: model,
                session: session,
                onDismiss: {
                    dismiss()
                }
            )
        } else {
            ContentUnavailableView(
                "Sign-in session unavailable",
                systemImage: "person.crop.circle.badge.exclamationmark",
                description: Text("Close this window and start again from Add Account.")
            )
            .frame(minWidth: 520, minHeight: 360)
        }
    }
}
