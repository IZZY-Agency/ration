import AppKit

/// Swallows mouse input while a freshly presented panel settles — the
/// attention drop and the ring bar.
///
/// The panel can materialise under the pointer, and AppKit then hands the
/// in-flight mouse state to the newly mapped window, which SwiftUI turns into a
/// press — the panel used to dismiss itself on launch. `ignoresMouseEvents` on
/// the window fixes that but makes the panel CLICK-THROUGH: a legitimate fast
/// click in those first milliseconds sails past and hits whatever is behind it.
/// A shield keeps the events, and drops them.
final class PresentationShieldView: NSView {
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
