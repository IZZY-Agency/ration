import AppKit
import Combine

/// Owns the appearance preference. Stored in UserDefaults — NOT AppSettings —
/// because it must be known synchronously before the first window, while
/// AppSettings hydrates asynchronously after other loads.
@MainActor
final class AppearanceController: ObservableObject {
    static let defaultsKey = "appearanceMode"

    @Published private(set) var mode: AppearanceMode
    private let defaults: UserDefaults
    private let application: NSApplication
    private var listeners: [UUID: @MainActor (NSAppearance?) -> Void] = [:]
    /// Cancelled with the controller.
    private var accessibilityDisplayObservation: AnyCancellable?

    /// - Parameter workspaceNotificationCenter: where Increase Contrast
    ///   changes arrive (`NSWorkspace.shared.notificationCenter`); injectable
    ///   so tests can post the change.
    init(
        defaults: UserDefaults = .standard,
        application: NSApplication = .shared,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.defaults = defaults
        self.application = application
        mode = defaults.string(forKey: Self.defaultsKey).flatMap(AppearanceMode.init(rawValue:)) ?? .system
        // `Theme`'s Increase Contrast tones read the system flag at draw time,
        // but nothing redraws a colour assigned once (window grounds, the
        // status icon, the popover) — re-apply so every listener repaints.
        accessibilityDisplayObservation = workspaceNotificationCenter
            .publisher(for: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
            .sink { [weak self] _ in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.apply() }
                } else {
                    DispatchQueue.main.async { self?.apply() }
                }
            }
    }

    func setMode(_ newMode: AppearanceMode) {
        mode = newMode
        defaults.set(newMode.rawValue, forKey: Self.defaultsKey)
        apply()
    }

    /// Sets the app appearance, then every existing window explicitly (a
    /// window's own `appearance` wins over the app's, and some AppKit
    /// surfaces don't reliably inherit), then tells listeners — the popover,
    /// the drop panel and anything holding a colour assigned once.
    ///
    /// `window.appearance = nil` for System makes the window inherit
    /// `NSApp.appearance` (also nil), so System keeps tracking macOS live.
    func apply() {
        let appearance = mode.nsAppearance
        application.appearance = appearance
        for window in application.windows where !Self.isMenuBarWindow(window) {
            window.appearance = appearance
            window.contentView?.needsDisplay = true
        }
        for listener in listeners.values { listener(appearance) }
    }

    /// The system's status-item windows. Their appearance belongs to the menu
    /// bar (vibrant, following the wallpaper/OS), not to the app: overriding it
    /// draws a template icon dark-on-dark after a live switch.
    ///
    /// Matched by class name, not by `level == .statusBar`: our own drop panel
    /// also sits at `.statusBar` and must be restyled. The class is private,
    /// so `testSetModeLeavesStatusItemAppearanceAlone` pins it — a rename
    /// fails that test rather than silently regressing the icon.
    private static func isMenuBarWindow(_ window: NSWindow) -> Bool {
        window.className == "NSStatusBarWindow"
    }

    @discardableResult
    func addApplyListener(_ body: @escaping @MainActor (NSAppearance?) -> Void) -> UUID {
        let id = UUID()
        listeners[id] = body
        return id
    }

    func removeApplyListener(_ id: UUID) {
        listeners[id] = nil
    }
}
