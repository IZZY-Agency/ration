import AppKit
import Carbon.HIToolbox
import Combine
import SwiftUI

@MainActor
protocol PopoverPresenting: AnyObject {
    var isShown: Bool { get }
    var behavior: NSPopover.Behavior { get set }
    var contentViewController: NSViewController? { get set }
    var appearance: NSAppearance? { get set }
    var hasFullSizeContent: Bool { get set }
    var delegate: (any NSPopoverDelegate)? { get set }

    func show(
        relativeTo positioningRect: NSRect,
        of positioningView: NSView,
        preferredEdge: NSRectEdge
    )
    func performClose(_ sender: Any?)
    func close()
}

extension NSPopover: PopoverPresenting {}

@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private let launchAtLogin: LaunchAtLoginController
    private let appearance: AppearanceController
    /// The single appearance listener registered in `start()`, removed in
    /// `stop()`.
    private var appearanceListenerID: UUID?
    private(set) var statusItem: NSStatusItem?
    private let popover: any PopoverPresenting
    private let hotKeyRegistrar: any GlobalHotKeyRegistering
    private let popoverPin: AccountPinSnapshot
    private let fallbackPin: AccountPinSnapshot
    private var hotKeyController: GlobalHotKeyController?
    private var fallbackWindowController: NSWindowController?
    private var addAccountWindowController: NSWindowController?
    private var settingsWindowController: NSWindowController?
    private var aboutWindowController: NSWindowController?
    private var historyWindowController: NSWindowController?
    private var onboardingWindowController: NSWindowController?
    private var signInWindowControllers: [UUID: NSWindowController] = [:]
    private var windowCloseObservers: [ObjectIdentifier: WindowCloseObserver] = [:]

    /// Clock for the in-use indicator; injectable so tests can age the phase
    /// without waiting the bright-threshold out in real time.
    private let now: () -> Date
    /// One Carbon registrar per popover shortcut (see `PopoverShortcut`).
    private let makePopoverHotKeyRegistrar: () -> any GlobalHotKeyRegistering
    /// The Refresh and Quit footer actions — injectable so tests can observe
    /// them without refreshing real accounts or terminating the test host.
    private let refreshAction: () -> Void
    private let terminateApp: () -> Void
    /// The popover shortcuts claimed for the current presentation, by key.
    /// Empty whenever the popover is closed.
    private var popoverHotKeys: [PopoverShortcut: any GlobalHotKeyRegistering] = [:]
    /// Keys another app refused us during this presentation — not retried
    /// until the popover is presented again.
    private var refusedPopoverShortcuts: Set<PopoverShortcut> = []
    private var popoverShortcutsActive = false
    /// Key codes resolved from the keyboard layout for the current
    /// presentation.
    private var popoverKeyCodes: [PopoverShortcut: UInt32] = [:]
    private let popoverKeyCode: @MainActor (PopoverShortcut) -> UInt32
    /// Whether the status item sits in the menu bar where a popover can hang
    /// from it. Nil: ask the real geometry.
    private let statusItemIsAnchoredOverride: (() -> Bool)?
    private var attentionPresenceCancellable: AnyCancellable?
    private var inUseCancellables: Set<AnyCancellable> = []
    /// Test seam: the periodic tick that expires a dot on its own once the
    /// last burn ages past the bright IN USE threshold. Nil after `stop()`.
    private(set) var inUseTimer: Timer?

    /// The attention drop. Created lazily on first use so an install that
    /// never crosses a threshold never builds a panel at all.
    private var attentionPanel: AttentionDropPanel?
    private var attentionHostingView: NSHostingView<AttentionDropView>?
    /// The panel's data. Mutated in place so SwiftUI diffs rather than the
    /// whole tree being replaced — see `AttentionDropModelObject`.
    private let attentionModel = AttentionDropModelObject()
    /// Identifies the current presentation, so a settle timer from a panel
    /// that has since been closed cannot re-enable mouse input on a newer one.
    private var attentionSettleToken: UUID?
    /// Row ids the drop showed at its last refresh — the dedupe for its
    /// VoiceOver announcement (see `AttentionDropAnnouncement`).
    private var attentionAnnouncedIDs: Set<AttentionRow.ID> = []
    /// Whether the drop is on screen, for the popover's keyboard route to the
    /// panel's ✕. Its own object so the popover is not invalidated by every
    /// refresh tick of the drop's rows.
    let attentionPresence = AttentionDropPresence()
    private var attentionObservers: [any NSObjectProtocol] = []

    private var statusItemFrameObservation: NSKeyValueObservation?
    /// Redraws the rings when the menu bar's OWN appearance changes (macOS
    /// light/dark switch, wallpaper tint) — independent of the app setting,
    /// whose changes arrive through the appearance apply listener.
    private var buttonAppearanceObservation: NSKeyValueObservation?
    /// Re-resolves the popover's System appearance when macOS flips.
    private var systemAppearanceObservation: NSKeyValueObservation?

    /// Cadence of the expiry tick — the same 60s the popover's `InUseMarker`
    /// uses, so both surfaces age out within a minute of each other.
    static let inUseTickInterval: TimeInterval = 60
    /// How long a freshly presented drop ignores mouse input. Long enough to
    /// outlast the stale event AppKit delivers on presentation, short enough
    /// that a user reaching for the ✕ never notices.
    static let attentionSettleDelay: TimeInterval = 0.35

    init(
        model: AppModel,
        launchAtLogin: LaunchAtLoginController,
        appearance: AppearanceController = AppearanceController(),
        popover: any PopoverPresenting = NSPopover(),
        hotKeyRegistrar: any GlobalHotKeyRegistering = CarbonHotKeyRegistrar(),
        popoverPin: AccountPinSnapshot = AccountPinSnapshot(),
        fallbackPin: AccountPinSnapshot = AccountPinSnapshot(),
        now: @escaping () -> Date = { .now },
        makePopoverHotKeyRegistrar: @escaping () -> any GlobalHotKeyRegistering = { CarbonHotKeyRegistrar() },
        refreshAll: (() -> Void)? = nil,
        terminateApp: @escaping () -> Void = { NSApplication.shared.terminate(nil) },
        statusItemIsAnchored: (() -> Bool)? = nil,
        popoverKeyCode: @escaping @MainActor (PopoverShortcut) -> UInt32 = ShortcutKeyCodeResolver.liveKeyCode
    ) {
        self.model = model
        self.launchAtLogin = launchAtLogin
        self.appearance = appearance
        self.popover = popover
        self.hotKeyRegistrar = hotKeyRegistrar
        self.popoverPin = popoverPin
        self.fallbackPin = fallbackPin
        self.now = now
        self.makePopoverHotKeyRegistrar = makePopoverHotKeyRegistrar
        self.refreshAction = refreshAll ?? { [model] in
            Task { await model.refreshAll() }
        }
        self.terminateApp = terminateApp
        self.statusItemIsAnchoredOverride = statusItemIsAnchored
        self.popoverKeyCode = popoverKeyCode
        super.init()
    }

    func start() {
        guard statusItem == nil else { return }

        let item = StatusItemFactory.make()
        statusItem = item

        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            // Redraw synchronously inside the callback (it arrives on the main
            // thread, like the frame observer's): a hop through `Task` could
            // land after `stop()` and resurrect the drop on a dead controller.
            buttonAppearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.statusItem != nil else { return }
                    self.updateGauges()
                }
            }
        }

        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: makeMenuBarContent(pinSnapshot: popoverPin)
        )
        popover.appearance = popoverAppearance()
        // The popover chrome is translucent Liquid Glass: its appearance
        // follows the app, but its colour comes from what is behind it — the
        // menu bar — so in Light-on-a-dark-menu-bar the chevron drew dark grey.
        // Full-size content lets the content's `Theme.ink` background (which
        // ignores safe areas) paint the chevron too; the safe-area insets keep
        // the actual content inside the body.
        popover.hasFullSizeContent = true

        // Live switching: `AppearanceController.apply()` restyles every
        // window itself; this covers what it cannot reach — the popover (not
        // in `NSApp.windows` while closed), the drop panel, window grounds
        // assigned once, and the status item's drawn gauges.
        appearanceListenerID = appearance.addApplyListener { [weak self] resolved in
            guard let self else { return }
            popover.appearance = popoverAppearance()
            attentionPanel?.appearance = resolved
            for controller in managedWindowControllers {
                controller.window?.backgroundColor = Theme.inkNS
            }
            updateGauges()
        }

        // System mode: macOS flipping light/dark while the popover is open
        // must restyle it too — it holds a CONCRETE appearance (see
        // `popoverAppearance()`), which no longer tracks the OS by itself.
        systemAppearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, self.statusItem != nil else { return }
                self.popover.appearance = self.popoverAppearance()
            }
        }

        startInUseIndicator()

        // ⌘D follows the drop while the popover is open. `@Published` emits
        // before the value is stored, so the new value is passed through.
        attentionPresenceCancellable = attentionPresence.$isShowing
            .removeDuplicates()
            .sink { [weak self] showing in
                self?.syncPopoverShortcuts(dropShowing: showing)
            }

        // ⌥⌘U opens the window even when macOS 26 hides the status item.
        let hotKeyController = GlobalHotKeyController(
            registrar: hotKeyRegistrar
        ) { [weak self] in
            self?.toggleFallbackWindow()
        }
        if !hotKeyController.register() {
            NSLog(
                "Ration: ⌥⌘U hotkey registration failed; open the window by double-clicking Ration."
            )
        }
        self.hotKeyController = hotKeyController
    }

    /// ⌥⌘U behavior: hide the window when it is already the frontmost/key window
    /// of the active app; otherwise summon and focus it (including when it is
    /// open but buried behind another app).
    func toggleFallbackWindow() {
        let window = fallbackWindowController?.window
        let shouldHide = MenuBarController.shouldHideOnToggle(
            isVisible: window?.isVisible ?? false,
            appIsActive: NSApp.isActive,
            windowIsKey: window?.isKeyWindow ?? false
        )
        if shouldHide {
            window?.orderOut(nil)
        } else {
            showFallbackWindow()
        }
    }

    /// Hide only when the window is already the key window of the active app;
    /// in every other case (hidden, buried behind another app, or not key) the
    /// press should summon and focus it.
    static func shouldHideOnToggle(
        isVisible: Bool,
        appIsActive: Bool,
        windowIsKey: Bool
    ) -> Bool {
        isVisible && appIsActive && windowIsKey
    }

    func showFallbackWindow() {
        prepareForWindowPresentation()

        if let fallbackWindowController {
            if AccountPinSnapshot.shouldCapture(
                isNewWindow: false,
                isVisible: fallbackWindowController.window?.isVisible ?? false
            ) {
                capturePin(fallbackPin)
            }
            focus(fallbackWindowController)
            return
        }

        capturePin(fallbackPin)
        let controller = makeWindowController(
            title: "Ration",
            defaultSize: NSSize(width: 400, height: 470),
            minimumSize: NSSize(width: 400, height: 320),
            styleMask: standardWindowStyle,
            rootView: makeMenuBarContent(pinSnapshot: fallbackPin)
        )
        fallbackWindowController = controller
        observeClose(of: controller) { [weak self, weak controller] in
            guard self?.fallbackWindowController === controller else { return }
            self?.fallbackWindowController = nil
        }
        focus(controller)
    }

    /// Wires the in-use dots to everything that can change them: a new burn
    /// (history publishes), an account added/removed/paused (model publishes),
    /// the settings toggle, and a periodic tick so a dot expires on its own —
    /// the status item lives outside SwiftUI observation, so nothing else
    /// would ever redraw it.
    private func startInUseIndicator() {
        updateGauges()

        model.history.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateGauges() }
            .store(in: &inUseCancellables)

        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateGauges() }
            .store(in: &inUseCancellables)

        // AppSettings is its own ObservableObject — the model subscription
        // above never sees the toggle, window-selection, or display-mode
        // changes, so subscribe to the whole settings object.
        model.settings.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateGauges() }
            .store(in: &inUseCancellables)

        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.inUseTickInterval,
            repeats: true
        ) { [weak self] _ in
            // Scheduled and fired on the main run loop. Weak on the OUTER
            // closure: the run loop retains a repeating timer, and a strong
            // capture here would pin the controller until invalidate().
            MainActor.assumeIsolated {
                self?.updateGauges()
            }
        }
        timer.tolerance = 5
        inUseTimer = timer

        startAttentionDrop()
    }

    // MARK: - Attention drop

    /// The drop is DERIVED, so something has to ask it to re-derive: nothing
    /// publishes when quiet hours end, and an open panel would not close
    /// itself when its evidence ages out. It rides the gauge tick rather than
    /// starting a second clock — one cadence, nothing to drift — and
    /// `updateGauges` already runs on every publish that can change a row
    /// (history, model, settings) as well as the 60s timer.
    private func startAttentionDrop() {
        // A screen being added, removed or resized moves where the panel
        // belongs; recompute placement rather than leaving it on a display
        // that may no longer exist.
        let screens = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAttentionDrop() }
        }
        attentionObservers.append(screens)

        // The status item is variable-width, so a gauge update can move its
        // left edge while a panel is open — follow the button's window frame
        // so an open panel stays under it.
        if let window = statusItem?.button?.window {
            statusItemFrameObservation = window.observe(\.frame) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.positionAttentionPanel() }
            }
        }
    }

    /// Recomputes the rows and shows, updates or closes the panel to match.
    ///
    /// Cheap to call often, which matters: this rides three publishers plus
    /// the tick and can run a dozen times in a tenth of a second at startup.
    /// It only mutates the observable model — the hosting view and its SwiftUI
    /// tree are created once and never replaced.
    func refreshAttentionDrop() {
        let rows = model.attentionRows(now: now())
        guard !rows.isEmpty else {
            closeAttentionPanel()
            return
        }

        let anchoredToStatusItem: Bool
        if case .statusItem = currentAnchor() { anchoredToStatusItem = true }
        else { anchoredToStatusItem = false }

        attentionModel.rows = rows
        // Rides the model subscription like the rows: `switchAdvice` is
        // `@Published` on `AppModel`, so a change re-runs this.
        if attentionModel.switchAdvice != model.switchAdvice {
            attentionModel.switchAdvice = model.switchAdvice
        }
        attentionModel.now = now()
        attentionModel.showsTicker = anchoredToStatusItem
        attentionModel.availableRowsHeight = AttentionDropGeometry.availableRowsHeight(
            visibleFrame: currentVisibleFrame()
        )

        if attentionPanel == nil {
            attentionModel.onDismissAll = { [weak self] in
                self?.dismissAttentionDrop()
            }
            attentionModel.onSelect = { [weak self] row in
                guard let self else { return }
                self.model.dismissAttentionRows([row])
                self.refreshAttentionDrop()
                self.showPopoverFromDrop()
            }
            let hosting = NSHostingView(rootView: AttentionDropView(model: attentionModel))
            let panel = AttentionDropPanel()
            panel.appearance = appearance.mode.nsAppearance
            panel.contentView = hosting
            attentionHostingView = hosting
            attentionPanel = panel

            // The panel appears on its own schedule, so it can materialise
            // directly UNDER the pointer — and when it does, AppKit delivers
            // the in-flight mouse state to the freshly mapped window and
            // SwiftUI turns it into a press. Measured: with the cursor parked
            // where the ✕ lands, the panel dismissed every row on launch
            // without anyone touching the mouse; moved 900px away, zero
            // dismissals.
            //
            // A SHIELD rather than `ignoresMouseEvents`: that flag makes the
            // whole window transparent to the mouse, so a legitimate fast click
            // in those first milliseconds would sail through and land on
            // whatever application is behind the panel. The shield keeps the
            // events and drops them.
            let shield = AttentionDropShieldView(frame: hosting.bounds)
            shield.autoresizingMask = [.width, .height]
            panel.contentView?.addSubview(shield)
            let settleToken = UUID()
            attentionSettleToken = settleToken
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.attentionSettleDelay) { [weak self, weak shield] in
                MainActor.assumeIsolated {
                    guard let self, self.attentionSettleToken == settleToken else { return }
                    // Hold the shield while a button is still physically down —
                    // re-enabling mid-press is what produced the phantom click
                    // in the first place.
                    guard NSEvent.pressedMouseButtons == 0 else {
                        self.retryAttentionSettle(token: settleToken, shield: shield)
                        return
                    }
                    shield?.removeFromSuperview()
                }
            }
        }

        positionAttentionPanel()
        attentionPanel?.orderFrontRegardless()
        attentionPresence.set(true)

        // The panel never becomes key, so VoiceOver would never find it on
        // its own — announce it, once per appearance or new row.
        let announcement = AttentionDropAnnouncement.evaluate(
            rows: rows,
            previouslySeen: attentionAnnouncedIDs
        )
        attentionAnnouncedIDs = announcement.seen
        if let text = announcement.announcement {
            AttentionDropAnnouncement.post(text)
        }
    }

    /// The panel's ✕, and the popover's keyboard route to it: snoozes the
    /// drop (acknowledging its reset rows) and closes it.
    func dismissAttentionDrop() {
        guard !attentionModel.rows.isEmpty else { return }
        // Dismiss exactly what is on screen — re-deriving here could pick up
        // a row that appeared after the user decided to clear.
        model.snoozeAttentionDrop(attentionModel.rows)
        refreshAttentionDrop()
    }

    /// The status-item button's frame in screen coordinates, or nil.
    ///
    /// `button.bounds` converted directly is wrong when the button is not at
    /// its window's origin — the conversion goes through the window.
    private func statusItemFrameInScreen() -> NSRect? {
        statusItem?.button.flatMap { button in
            button.window.map { $0.convertToScreen(button.convert(button.bounds, to: nil)) }
        }
    }

    /// The visible frame of the screen the panel will appear on.
    private func currentVisibleFrame() -> NSRect {
        let buttonFrame = statusItemFrameInScreen()
        let screenFrames = NSScreen.screens.map(\.frame)
        let mainFrame = NSScreen.main?.frame ?? screenFrames.first ?? .zero
        let screenFrame = AttentionDropGeometry.screen(
            forButtonFrame: buttonFrame,
            screens: screenFrames,
            main: mainFrame
        )
        return NSScreen.screens.first { $0.frame == screenFrame }?.visibleFrame ?? screenFrame
    }

    /// Which anchor the geometry would choose right now.
    private func currentAnchor() -> AttentionDropGeometry.Anchor {
        let buttonFrame = statusItemFrameInScreen()
        let screenFrames = NSScreen.screens.map(\.frame)
        let mainFrame = NSScreen.main?.frame ?? screenFrames.first ?? .zero
        let screenFrame = AttentionDropGeometry.screen(
            forButtonFrame: buttonFrame,
            screens: screenFrames,
            main: mainFrame
        )
        let visibleFrame = NSScreen.screens
            .first { $0.frame == screenFrame }?
            .visibleFrame ?? screenFrame
        return AttentionDropGeometry.anchor(
            buttonFrameInScreen: buttonFrame,
            screen: screenFrame,
            visibleFrame: visibleFrame
        )
    }

    /// Places the panel with `AttentionDropGeometry`, which is where all the
    /// decisions live — this only supplies real frames.
    private func positionAttentionPanel() {
        guard let panel = attentionPanel, let hosting = attentionHostingView else { return }

        // Height follows the content; width is fixed so rows align.
        hosting.layoutSubtreeIfNeeded()
        let fitting = hosting.fittingSize
        let size = NSSize(
            width: AttentionDropPanel.width,
            height: max(fitting.height, 44)
        )

        let buttonFrame = statusItemFrameInScreen()
        let screenFrames = NSScreen.screens.map(\.frame)
        let mainFrame = NSScreen.main?.frame ?? screenFrames.first ?? .zero
        let screenFrame = AttentionDropGeometry.screen(
            forButtonFrame: buttonFrame,
            screens: screenFrames,
            main: mainFrame
        )
        let visibleFrame = NSScreen.screens
            .first { $0.frame == screenFrame }?
            .visibleFrame ?? screenFrame

        let anchor = AttentionDropGeometry.anchor(
            buttonFrameInScreen: buttonFrame,
            screen: screenFrame,
            visibleFrame: visibleFrame
        )
        panel.setFrame(
            AttentionDropGeometry.frame(
                anchor: anchor,
                screen: screenFrame,
                visibleFrame: visibleFrame,
                panelSize: size
            ),
            display: true
        )
    }

    /// Re-checks shortly after, for as long as a mouse button is held.
    private func retryAttentionSettle(token: UUID, shield: AttentionDropShieldView?) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self, weak shield] in
            MainActor.assumeIsolated {
                guard let self, self.attentionSettleToken == token else { return }
                guard NSEvent.pressedMouseButtons == 0 else {
                    self.retryAttentionSettle(token: token, shield: shield)
                    return
                }
                shield?.removeFromSuperview()
            }
        }
    }

    private func closeAttentionPanel() {
        attentionSettleToken = nil
        attentionAnnouncedIDs = []
        attentionPresence.set(false)
        attentionModel.rows = []
        attentionPanel?.orderOut(nil)
        attentionPanel?.contentView = nil
        attentionPanel = nil
        attentionHostingView = nil
    }

    /// Opening the popover from a drop row: the drop never activates the app
    /// on its own, but a click is explicit intent, so this behaves exactly
    /// like clicking the status item.
    ///
    /// When the status item is not in the menu bar (hidden behind the notch,
    /// parked by the system) there is nothing to hang a popover from — the
    /// window opens instead.
    private func showPopoverFromDrop() {
        guard !popover.isShown else { return }
        guard let button = statusItem?.button, statusItemIsAnchored() else {
            showFallbackWindow()
            return
        }
        presentPopover(from: button)
    }

    private func statusItemIsAnchored() -> Bool {
        if let statusItemIsAnchoredOverride { return statusItemIsAnchoredOverride() }
        if case .statusItem = currentAnchor() { return true }
        return false
    }

    /// Recomputes the usage gauges — a ring per visible account, the in-use
    /// dot from the popover pill's burn rules but WITHOUT its per-provider
    /// dedup (`ActiveUsageMap.computePerAccount`: two same-provider accounts
    /// in parallel use both get a dot), values from the snapshot store — and
    /// renders them onto the status item button.
    func updateGauges() {
        // The drop shares this entry point deliberately — see
        // `startAttentionDrop()`. It must run even when there is no status
        // item button to draw gauges onto, so it goes before the guard.
        refreshAttentionDrop()

        guard let button = statusItem?.button else { return }
        let displaysRemaining = model.settings.menuBarDisplaysRemaining
        let gauges: [MenuBarGauge]
        if model.settings.showInUseInMenuBar {
            let at = now()
            let accounts = model.visibleAccounts
            // Materialized here because `gauges` is a nonisolated pure
            // function — its closures cannot call back into MainActor state.
            let snapshots = Dictionary(
                uniqueKeysWithValues: accounts.compactMap { account in
                    model.snapshot(for: account.id).map { (account.id, $0) }
                }
            )
            let windowKinds = Dictionary(
                uniqueKeysWithValues: Provider.allCases.map {
                    ($0, model.settings.menuBarWindow(for: $0))
                }
            )
            gauges = MenuBarGaugeState.gauges(
                accounts: accounts,
                // In-use detection off → no green center dots; the rings
                // themselves stay (they are `showInUseInMenuBar`'s).
                activeUsage: model.settings.featureInUseEnabled
                    ? ActiveUsageMap.computePerAccount(accounts: accounts, history: model.history, now: at)
                    : [:],
                snapshots: { snapshots[$0] },
                windowKind: { windowKinds[$0] ?? AppSettingsData.defaultMenuBarWindow(for: $0) },
                displaysRemaining: displaysRemaining,
                now: at
            )
        } else {
            gauges = []
        }
        StatusItemFactory.applyGauges(
            gauges,
            displaysRemaining: displaysRemaining,
            to: button
        )
    }

    func stop() {
        inUseCancellables.removeAll()
        inUseTimer?.invalidate()
        inUseTimer = nil

        statusItemFrameObservation?.invalidate()
        statusItemFrameObservation = nil
        buttonAppearanceObservation?.invalidate()
        buttonAppearanceObservation = nil
        systemAppearanceObservation?.invalidate()
        systemAppearanceObservation = nil
        for observer in attentionObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        attentionObservers.removeAll()
        closeAttentionPanel()

        hotKeyController?.unregister()
        hotKeyController = nil
        attentionPresenceCancellable = nil
        popover.close()
        // `close()` is not guaranteed to report `popoverDidClose`; releasing
        // is idempotent, so the popover keys never outlive the controller.
        endPopoverShortcuts()
        popover.delegate = nil

        appearanceListenerID.map(appearance.removeApplyListener)
        appearanceListenerID = nil

        let windowControllers = managedWindowControllers

        fallbackWindowController = nil
        addAccountWindowController = nil
        settingsWindowController = nil
        aboutWindowController = nil
        historyWindowController = nil
        onboardingWindowController = nil
        signInWindowControllers.removeAll()
        windowCloseObservers.removeAll()

        for controller in windowControllers {
            controller.window?.delegate = nil
            controller.close()
        }

        popover.contentViewController = nil

        if let statusItem {
            statusItem.button?.target = nil
            statusItem.button?.action = nil
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    /// The popover's appearance: ALWAYS concrete. Left `nil` (System), a
    /// shown popover inherits its positioning view — the status button, whose
    /// appearance is the MENU BAR's — so on a dark bar with Light macOS it
    /// came up dark beside light windows. System resolves to what macOS
    /// itself is (`NSApp.effectiveAppearance`, app appearance being nil),
    /// reduced to plain aqua/darkAqua so no vibrant variant leaks in.
    private func popoverAppearance() -> NSAppearance? {
        if let explicit = appearance.mode.nsAppearance { return explicit }
        let name = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) ?? .aqua
        return NSAppearance(named: name)
    }

    /// Every AppKit window controller this controller owns.
    private var managedWindowControllers: [NSWindowController] {
        [
            fallbackWindowController,
            addAccountWindowController,
            settingsWindowController,
            aboutWindowController,
            historyWindowController,
            onboardingWindowController
        ].compactMap { $0 } + Array(signInWindowControllers.values)
    }

    @objc
    private func togglePopover(_ sender: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(sender)
        } else {
            presentPopover(from: sender)
        }
    }

    /// The one way the popover is shown — the status item and a drop row both
    /// come here.
    ///
    /// Ration is an LSUIElement app and is NOT activated here: since macOS 14
    /// `activate()` is only a request the frontmost app may ignore (it did —
    /// the popover never became key), and activation drags Space/Dock side
    /// effects along. The popover's ⌘ shortcuts are instead claimed as
    /// global hotkeys for exactly as long as it is shown — claimed on
    /// `popoverDidShow`, so a show AppKit never performs claims nothing.
    private func presentPopover(from button: NSStatusBarButton) {
        capturePin(popoverPin)
        popover.appearance = popoverAppearance()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    // MARK: - Popover shortcuts

    private func beginPopoverShortcuts() {
        endPopoverShortcuts()
        popoverShortcutsActive = true
        popoverKeyCodes = Dictionary(
            uniqueKeysWithValues: PopoverShortcut.allCases.map { ($0, popoverKeyCode($0)) }
        )
        syncPopoverShortcuts(dropShowing: attentionPresence.isShowing)
    }

    /// Claims exactly the keys the open popover offers — ⌘D only while the
    /// drop is up, so ⌘D is never taken from the frontmost app for a button
    /// that is not even on screen.
    private func syncPopoverShortcuts(dropShowing: Bool) {
        guard popoverShortcutsActive else { return }
        let wanted = Set(PopoverShortcut.allCases.filter { $0 != .dismissAlerts || dropShowing })

        for shortcut in popoverHotKeys.keys where !wanted.contains(shortcut) {
            popoverHotKeys.removeValue(forKey: shortcut)?.unregister()
        }
        for shortcut in PopoverShortcut.allCases
        where wanted.contains(shortcut)
            && popoverHotKeys[shortcut] == nil
            && !refusedPopoverShortcuts.contains(shortcut) {
            let registrar = makePopoverHotKeyRegistrar()
            let registered = registrar.register(
                keyCode: popoverKeyCodes[shortcut] ?? shortcut.ansiKeyCode,
                modifiers: PopoverShortcut.modifiers,
                exclusive: true
            ) { [weak self] in
                self?.perform(shortcut)
            }
            if registered {
                popoverHotKeys[shortcut] = registrar
            } else {
                refusedPopoverShortcuts.insert(shortcut)
                NSLog("Ration: \(shortcut) hotkey is owned by another app; skipped while the popover is open.")
            }
        }
    }

    /// The single release point for the popover keys: `popoverDidClose`
    /// (toggle, click-away, Esc, opening a window) and `stop()`.
    private func endPopoverShortcuts() {
        popoverShortcutsActive = false
        refusedPopoverShortcuts = []
        for registrar in popoverHotKeys.values {
            registrar.unregister()
        }
        popoverHotKeys = [:]
    }

    /// The same paths the popover's buttons run.
    private func perform(_ shortcut: PopoverShortcut) {
        switch shortcut {
        case .refresh: refreshAction()
        case .settings: showSettings()
        case .quit: terminateApp()
        case .dismissAlerts: dismissAttentionDrop()
        }
    }

    private func showAddAccount() {
        prepareForWindowPresentation()

        if let addAccountWindowController {
            focus(addAccountWindowController)
            return
        }

        let controller = makeWindowController(
            title: "Add Account",
            // 530: the content measured 495 pt with a one-line subtitle; the
            // wrapped second line adds ≈18 pt, plus a little slack so the
            // Cancel row never sits on the edge.
            defaultSize: NSSize(width: 420, height: 530),
            minimumSize: NSSize(width: 420, height: 530),
            styleMask: standardWindowStyle,
            rootView: AddAccountView(
                model: model,
                onOpenSignIn: { [weak self] sessionID in
                    self?.showSignIn(sessionID: sessionID)
                },
                onDismiss: { [weak self] in
                    self?.addAccountWindowController?.close()
                }
            )
        )
        addAccountWindowController = controller
        observeClose(of: controller) { [weak self, weak controller] in
            guard self?.addAccountWindowController === controller else { return }
            self?.addAccountWindowController = nil
        }
        focus(controller)
    }

    private func showSettings() {
        prepareForWindowPresentation()

        if let settingsWindowController {
            focus(settingsWindowController)
            return
        }

        let controller = makeWindowController(
            title: "Settings",
            defaultSize: NSSize(width: SettingsView.minimumWindowWidth, height: 564),
            minimumSize: NSSize(width: SettingsView.minimumWindowWidth, height: 470),
            styleMask: standardWindowStyle,
            escClosable: true,
            rootView: SettingsView(
                model: model,
                launchAtLogin: launchAtLogin,
                appearance: appearance,
                history: model.history,
                onAddAccount: { [weak self] in
                    self?.showAddAccount()
                },
                onOpenSignIn: { [weak self] sessionID in
                    self?.showSignIn(sessionID: sessionID)
                },
                onOpenSetupGuide: { [weak self] in
                    self?.showOnboarding()
                }
            )
        )
        settingsWindowController = controller
        observeClose(of: controller) { [weak self, weak controller] in
            guard self?.settingsWindowController === controller else { return }
            self?.settingsWindowController = nil
        }
        focus(controller)
    }

    private func showAbout() {
        prepareForWindowPresentation()

        if let aboutWindowController {
            focus(aboutWindowController)
            return
        }

        // 286: at the +2pt sizes the About stack measures ≈283pt (28pt
        // padding ×2, 88pt icon, 4×13pt spacing, then the name/version/
        // copyright/link lines) — 270 no longer held it.
        let contentSize = NSSize(width: 360, height: 286)
        let controller = makeWindowController(
            title: "About Ration",
            defaultSize: contentSize,
            minimumSize: contentSize,
            maximumSize: contentSize,
            styleMask: [.titled, .closable],
            escClosable: true,
            rootView: AboutView()
        )
        aboutWindowController = controller
        observeClose(of: controller) { [weak self, weak controller] in
            guard self?.aboutWindowController === controller else { return }
            self?.aboutWindowController = nil
        }
        focus(controller)
    }

    /// The first-run wizard. Marks onboarding complete on ANY close — Done,
    /// Skip, or the traffic light — so it is shown once and never nags. Both
    /// re-entry points (Settings → General, and the popover's empty state) call
    /// straight back into here.
    ///
    /// Note that `stop()` detaches window delegates before closing, so quitting
    /// the app with the wizard still open does NOT mark it complete: a user who
    /// never dismissed it gets it again next launch.
    /// Test seam: whether the Setup Guide window is currently open. Asserting
    /// on this rather than on the delegate's latch is what makes the
    /// termination test non-vacuous — the latch stays false whether or not a
    /// window was actually shown.
    var hasOnboardingWindow: Bool { onboardingWindowController != nil }

    var hasSettingsWindow: Bool { settingsWindowController != nil }

    var hasFallbackWindow: Bool { fallbackWindowController != nil }

    /// Test seam: a click on a drop row.
    func openPopoverFromDropForTesting() {
        showPopoverFromDrop()
    }

    /// Test seam: closes the Setup Guide the way the traffic light does, so a
    /// test can re-arm and assert a second presentation.
    func closeOnboardingForTesting() {
        onboardingWindowController?.close()
    }

    func showOnboarding() {
        prepareForWindowPresentation()

        if let onboardingWindowController {
            focus(onboardingWindowController)
            return
        }

        let controller = makeWindowController(
            title: "Setup Guide",
            defaultSize: NSSize(width: 540, height: 560),
            minimumSize: NSSize(width: 520, height: 480),
            styleMask: standardWindowStyle,
            escClosable: true,
            rootView: OnboardingView(
                model: model,
                launchAtLogin: launchAtLogin,
                onOpenSignIn: { [weak self] sessionID in
                    self?.showSignIn(sessionID: sessionID)
                },
                onFinish: { [weak self] in
                    self?.onboardingWindowController?.close()
                }
            )
        )
        onboardingWindowController = controller
        observeClose(of: controller) { [weak self, weak controller] in
            guard self?.onboardingWindowController === controller else { return }
            self?.onboardingWindowController = nil
            guard let model = self?.model else { return }
            Task { await model.markOnboardingCompleted() }
        }
        focus(controller)
    }

    private func showHistory() {
        prepareForWindowPresentation()

        if let historyWindowController {
            focus(historyWindowController)
            return
        }

        let controller = makeWindowController(
            title: "History",
            defaultSize: NSSize(width: 720, height: 520),
            minimumSize: NSSize(width: 680, height: 480),
            styleMask: standardWindowStyle,
            escClosable: true,
            rootView: HistoryView(model: model)
        )
        historyWindowController = controller
        observeClose(of: controller) { [weak self, weak controller] in
            guard self?.historyWindowController === controller else { return }
            self?.historyWindowController = nil
        }
        focus(controller)
    }

    private func showSignIn(sessionID: UUID) {
        prepareForWindowPresentation()

        if let controller = signInWindowControllers[sessionID] {
            focus(controller)
            return
        }

        guard let session = model.signInSession(for: sessionID) else { return }

        let controller = makeWindowController(
            title: "Sign In",
            defaultSize: NSSize(width: 760, height: 680),
            minimumSize: NSSize(width: 700, height: 620),
            styleMask: standardWindowStyle,
            rootView: SignInSessionView(
                model: model,
                session: session,
                onDismiss: { [weak self] in
                    self?.signInWindowControllers[sessionID]?.close()
                }
            )
        )
        signInWindowControllers[sessionID] = controller
        observeClose(of: controller) { [weak self, weak controller] in
            guard self?.signInWindowControllers[sessionID] === controller else {
                return
            }
            self?.signInWindowControllers.removeValue(forKey: sessionID)
        }
        focus(controller)
    }

    private var standardWindowStyle: NSWindow.StyleMask {
        [.titled, .closable, .miniaturizable, .resizable]
    }

    private func capturePin(_ snapshot: AccountPinSnapshot) {
        snapshot.refresh(
            accounts: model.visibleAccounts,
            history: model.history,
            now: .now,
            inUseEnabled: model.settings.featureInUseEnabled
        )
    }

    private func makeMenuBarContent(pinSnapshot: AccountPinSnapshot) -> MenuBarContent {
        MenuBarContent(
            model: model,
            history: model.history,
            pinSnapshot: pinSnapshot,
            settings: model.settings,
            onAddAccount: { [weak self] in
                self?.showAddAccount()
            },
            onSettings: { [weak self] in
                self?.showSettings()
            },
            onAbout: { [weak self] in
                self?.showAbout()
            },
            onHistory: { [weak self] in
                self?.showHistory()
            },
            onOpenSignIn: { [weak self] sessionID in
                self?.showSignIn(sessionID: sessionID)
            },
            onOpenSetupGuide: { [weak self] in
                self?.showOnboarding()
            },
            attentionPresence: attentionPresence,
            onDismissAttentionDrop: { [weak self] in
                self?.dismissAttentionDrop()
            },
            onRefresh: { [weak self] in
                self?.refreshAction()
            },
            onQuit: { [weak self] in
                self?.terminateApp()
            }
        )
    }

    private func prepareForWindowPresentation() {
        popover.performClose(nil)
        NSApplication.shared.activate()
    }

    private func focus(_ controller: NSWindowController) {
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func makeWindowController<Content: View>(
        title: String,
        defaultSize: NSSize,
        minimumSize: NSSize,
        maximumSize: NSSize? = nil,
        styleMask: NSWindow.StyleMask,
        escClosable: Bool = false,
        rootView: Content
    ) -> NSWindowController {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: defaultSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.backgroundColor = Theme.inkNS
        window.appearance = appearance.mode.nsAppearance
        // Blend the title bar into the izzy ground: transparent bar over the ink
        // background, no native title text — only the traffic lights remain.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentViewController = escClosable
            ? EscClosableHostingController(rootView: rootView)
            : NSHostingController(rootView: rootView)
        window.setContentSize(defaultSize)
        window.contentMinSize = minimumSize
        if let maximumSize {
            window.contentMaxSize = maximumSize
        }
        window.isReleasedWhenClosed = false
        window.center()
        return NSWindowController(window: window)
    }

    private func observeClose(
        of controller: NSWindowController,
        onClose: @escaping @MainActor () -> Void
    ) {
        guard let window = controller.window else { return }

        let key = ObjectIdentifier(window)
        let observer = WindowCloseObserver { [weak self] in
            onClose()
            self?.windowCloseObservers.removeValue(forKey: key)
        }
        windowCloseObservers[key] = observer
        window.delegate = observer
    }
}

extension MenuBarController: NSPopoverDelegate {
    /// AppKit reports both after the animation, so either can land late: a
    /// didShow after the popover already closed, or a didClose after it was
    /// shown again. Each acts only if the popover's state still agrees.
    func popoverDidShow(_ notification: Notification) {
        guard popover.isShown else { return }
        beginPopoverShortcuts()
    }

    func popoverDidClose(_ notification: Notification) {
        guard !popover.isShown else { return }
        endPopoverShortcuts()
    }
}

/// The popover's ⌘ shortcuts, claimed as global hotkeys while it is shown.
enum PopoverShortcut: CaseIterable, CustomStringConvertible {
    case refresh
    case settings
    case quit
    case dismissAlerts

    static let modifiers = UInt32(cmdKey)

    /// The character the shortcut types — what Cocoa key equivalents match.
    var character: String {
        switch self {
        case .refresh: "r"
        case .settings: ","
        case .quit: "q"
        case .dismissAlerts: "d"
        }
    }

    /// The US-layout key, used when the layout cannot be read.
    var ansiKeyCode: UInt32 {
        switch self {
        case .refresh: UInt32(kVK_ANSI_R)
        case .settings: UInt32(kVK_ANSI_Comma)
        case .quit: UInt32(kVK_ANSI_Q)
        case .dismissAlerts: UInt32(kVK_ANSI_D)
        }
    }

    var description: String {
        switch self {
        case .refresh: "⌘R"
        case .settings: "⌘,"
        case .quit: "⌘Q"
        case .dismissAlerts: "⌘D"
        }
    }
}

/// Hosts SwiftUI content and dismisses its window on the Escape key, so the
/// About / Settings / History info windows close with ⎋ on the AppKit
/// menu-bar path — where the SwiftUI scene's `.onExitCommand` (used only under
/// `--ui-testing`) does not apply.
@MainActor
private final class EscClosableHostingController<Content: View>: NSHostingController<Content> {
    override func cancelOperation(_ sender: Any?) {
        view.window?.performClose(sender)
    }
}

@MainActor
private final class WindowCloseObserver: NSObject, NSWindowDelegate {
    private let onClose: @MainActor () -> Void

    init(onClose: @escaping @MainActor () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
