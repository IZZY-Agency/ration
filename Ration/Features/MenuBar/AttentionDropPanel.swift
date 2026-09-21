import AppKit
import SwiftUI

/// The window the attention drop lives in.
///
/// An `NSPanel`, never an `NSPopover`: a popover activates the app, which
/// would steal focus from whatever the user is typing in — unacceptable for
/// something that appears on its own schedule rather than on a click.
///
/// The configuration below was verified empirically before being written, on
/// macOS 27: with `.nonactivatingPanel` plus `orderFrontRegardless()`, showing
/// the panel left `NSApp.isActive == false`, the panel non-key, and the
/// frontmost application unchanged.
final class AttentionDropPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 100),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = true
        level = .statusBar
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        // Nothing in the drop takes text input, and this panel must never
        // become key — a borderless panel that did would draw focus rings and
        // swallow the frontmost app's keystrokes.
        isMovable = false
    }

    static let width: CGFloat = 320

    /// A borderless panel refuses key status by default; keep it that way
    /// explicitly so a future content change cannot quietly opt in.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Swallows mouse input while a freshly presented panel settles.
///
/// The panel can materialise under the pointer, and AppKit then hands the
/// in-flight mouse state to the newly mapped window, which SwiftUI turns into a
/// press — the panel used to dismiss itself on launch. `ignoresMouseEvents` on
/// the window fixes that but makes the panel CLICK-THROUGH: a legitimate fast
/// click in those first milliseconds sails past and hits whatever is behind it.
/// A shield keeps the events, and drops them.
final class AttentionDropShieldView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Claim every point, so nothing beneath ever sees these events.
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool { false }
}
