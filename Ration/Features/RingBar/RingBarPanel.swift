import AppKit

/// The ring bar's window: never key, never main, never activating, on every
/// Space and fixed during Mission Control (Apple: `.stationary` keeps a
/// window visible there). Kept up while Ration is inactive — an `NSPanel`
/// hides on deactivate by default. Also the floating grip's strip. Open
/// for the tests' spy.
class RingBarPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 40),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        // Below the Dock (level 20) and the drop (`.statusBar`).
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = Self.collectionBehavior
        isOpaque = false
        backgroundColor = .clear
        // The glass draws its own edge.
        hasShadow = false
        isMovable = false
        animationBehavior = .none
        // VoiceOver named it nothing and called it a "system dialog".
        setAccessibilityTitle(SettingsSectionTitle.ringBar)
        setAccessibilitySubrole(.floatingWindow)
    }

    /// Probed on macOS 27.2: without `.fullScreenNone` the panel
    /// showed over another app's full-screen space; with it, it stays on the
    /// normal desktops only.
    static let collectionBehavior: NSWindow.CollectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenNone]

    /// A borderless panel refuses key status by default; keep it that way
    /// explicitly so a future content change cannot quietly opt in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Presses that are not on a gauge resize the bar (see `RingBarDragRouter`).
    var dragRouter: RingBarDragRouter?
    /// A right-click or Control-click anywhere on the bar: its menu.
    var onContextMenu: ((NSEvent) -> Void)?

    /// Every press reaches the window before any view: dividers and letters
    /// are drawn in front of the SwiftUI background, and the gaps between
    /// capsules hold no SwiftUI at all, so only here can all of them resize.
    override func sendEvent(_ event: NSEvent) {
        if let onContextMenu,
           event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {
            onContextMenu(event)
            return
        }
        // The rest of a Control-click belongs to the menu, not a drag.
        if event.modifierFlags.contains(.control), event.type == .leftMouseDragged || event.type == .leftMouseUp,
           onContextMenu != nil {
            return
        }
        if let dragRouter {
            let point = convertPoint(toScreen: event.locationInWindow)
            let consumed = switch event.type {
            case .leftMouseDown: dragRouter.mouseDown(at: point)
            case .leftMouseDragged: dragRouter.mouseDragged(at: point)
            case .leftMouseUp: dragRouter.mouseUp(at: point)
            default: false
            }
            if consumed { return }
        }
        super.sendEvent(event)
    }
}

/// Decides, press by press, whether the ring bar resizes: a press anywhere
/// but on a gauge (a divider, a provider letter, a gap, the padding) and a
/// move of at least `threshold` points. Gauges keep their clicks; a press
/// that does not move does nothing. Screen coordinates: `.began` carries the
/// press point, so the bar follows the pointer from where it was grabbed.
@MainActor
final class RingBarDragRouter {
    static let threshold: CGFloat = 3

    var isOnGauge: (NSPoint) -> Bool = { _ in false }
    /// False while the bar is hidden or its input is still settling.
    var isArmed: () -> Bool = { true }
    var onPhase: (RingBarResizePhase, NSPoint) -> Void = { _, _ in }

    private var pressedAt: NSPoint?
    private var dragging = false

    /// Returns whether the press is the router's (the window must not pass it on).
    func mouseDown(at point: NSPoint) -> Bool {
        // A drag whose mouse-up never came ends here, and its press stops
        // claiming the events that follow.
        if dragging { onPhase(.ended, point) }
        reset()
        guard isArmed(), !isOnGauge(point) else { return false }
        pressedAt = point
        dragging = false
        return true
    }

    func mouseDragged(at point: NSPoint) -> Bool {
        guard let start = pressedAt else { return false }
        if !dragging {
            guard hypot(point.x - start.x, point.y - start.y) >= Self.threshold else { return true }
            dragging = true
            onPhase(.began, start)
        }
        onPhase(.changed, point)
        return true
    }

    func mouseUp(at point: NSPoint) -> Bool {
        guard pressedAt != nil else { return false }
        pressedAt = nil
        if dragging {
            dragging = false
            onPhase(.ended, point)
        }
        return true
    }

    /// Forgets the press without a phase: the controller ended the drag
    /// itself (a rebuild, a lost mouse-up, the bar going away).
    func reset() {
        pressedAt = nil
        dragging = false
    }
}

/// A menu item that runs a closure (the bar's right-click menu).
@MainActor
final class RingBarMenuItem: NSMenuItem {
    private let handler: @MainActor () -> Void

    init(title: String, state: NSControl.StateValue = .off, handler: @escaping @MainActor () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
        self.state = state
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func run() {
        handler()
    }
}

/// The floating grip's drawing: rounded pills with a soft shadow, so they
/// read over whatever window is under them. Pills in this view's
/// coordinates (bottom-left origin, like the screen).
final class RingBarGripView: NSView {
    var pills: [NSRect] = [] {
        didSet { if pills != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let shadow = NSShadow()
        shadow.shadowBlurRadius = 3
        shadow.shadowOffset = .zero
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
        shadow.set()
        Theme.creamDimNS.withAlphaComponent(0.85).setFill()
        for pill in pills {
            let radius = min(pill.width, pill.height) / 2
            NSBezierPath(roundedRect: pill, xRadius: radius, yRadius: radius).fill()
        }
    }
}

/// The ring bar's hover card: above the bar and the Dock, never key, and
/// transparent to the mouse — it only shows.
final class RingBarCardPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: RingBarMetrics.cardWidth, height: 80),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        hidesOnDeactivate = false
        collectionBehavior = RingBarPanel.collectionBehavior
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
