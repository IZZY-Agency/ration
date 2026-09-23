import AppKit

/// Puts Ration in the Dock and ⌘-Tab while one of its windows is open, and
/// back to menu-bar-only when the last one closes.
///
/// Ration is an `LSUIElement` app, so by default none of its windows can be
/// reached with ⌘-Tab. That strands the Sign In window the moment the user
/// switches to their mail client for a magic link — and Settings and History
/// the same way. A menu-bar app that temporarily becomes `.regular` while it
/// has real windows is the standard way out.
enum DockPresence {
    /// What the decision needs to know about one window — kept separate from
    /// `NSWindow` so the rule is testable without creating windows.
    struct WindowTraits: Equatable {
        let isVisible: Bool
        let isMiniaturized: Bool
        let isTitled: Bool
        let isPanel: Bool
    }

    /// `.regular` while any real window is on screen or minimized (a minimized
    /// window can only come back through the Dock). Panels (the attention
    /// drop) and untitled windows (the popover, the status item) are chrome,
    /// not windows the user navigates to.
    static func policy(for windows: [WindowTraits]) -> NSApplication.ActivationPolicy {
        let hasRealWindow = windows.contains { window in
            window.isTitled && !window.isPanel && (window.isVisible || window.isMiniaturized)
        }
        return hasRealWindow ? .regular : .accessory
    }

    enum ReopenAction: Equatable {
        /// AppKit's default: activation brings the visible windows forward.
        case bringExistingForward
        case deminiaturize
        case showFallback
    }

    /// What a Dock-icon click does. It must lead back to the window the user
    /// left (Sign In, mid magic link), not open the dashboard over it — the
    /// dashboard is only for a click when Ration has no window at all.
    static func reopenAction(hasVisibleWindows: Bool, hasMiniaturizedWindow: Bool) -> ReopenAction {
        if hasVisibleWindows { return .bringExistingForward }
        if hasMiniaturizedWindow { return .deminiaturize }
        return .showFallback
    }

    /// The windows `policy(for:)` counts, from the live window list.
    @MainActor
    static func realWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.styleMask.contains(.titled) && !($0 is NSPanel) }
    }
}

/// Watches every window's lifecycle and applies `DockPresence.policy`.
@MainActor
final class DockPresenceController {
    private var observers: [NSObjectProtocol] = []
    private var pendingUpdate = false

    func start() {
        guard observers.isEmpty else { return }
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.willCloseNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.didChangeOcclusionStateNotification,
            // Hide Others can hide Ration without any window notification.
            NSApplication.didHideNotification,
            NSApplication.didUnhideNotification
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleUpdate() }
            }
        }
        scheduleUpdate()
    }

    /// Deferred one turn: at `willClose` the closing window is still visible,
    /// so evaluating synchronously would keep the Dock icon after the last
    /// window is gone. Coalesced, since one open fires several notifications.
    private func scheduleUpdate() {
        guard !pendingUpdate else { return }
        pendingUpdate = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.pendingUpdate = false
                self?.apply()
            }
        }
    }

    private func apply() {
        // A hidden app's windows all read invisible. Leave the policy alone:
        // dropping to menu-bar-only here would remove the Dock icon — the one
        // way back to those windows. Unhiding re-evaluates.
        guard !NSApp.isHidden else { return }
        let traits = NSApp.windows.map { window in
            DockPresence.WindowTraits(
                isVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized,
                isTitled: window.styleMask.contains(.titled),
                isPanel: window is NSPanel
            )
        }
        let wanted = DockPresence.policy(for: traits)
        guard NSApp.activationPolicy() != wanted else { return }
        // No activation here: this also runs on passive changes (a window
        // restored by Show All), and must not steal focus. The places that
        // open windows already activate the app themselves.
        NSApp.setActivationPolicy(wanted)
    }
}
