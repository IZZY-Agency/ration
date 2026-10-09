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
