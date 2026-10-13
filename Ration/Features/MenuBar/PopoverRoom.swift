import Combine
import SwiftUI

extension EnvironmentValues {
    /// How tall the popover's content may be on the screen the popover (or
    /// the ⌥⌘U window) opens on: the visible height less the surface's frame
    /// and a margin (`AccountListMetrics.room`). The view takes its own drawn
    /// chrome out of it and gives the account list the rest.
    ///
    /// `MenuBarContent` sets it from its surface's `PopoverRoom`. The default
    /// is a fixed height, so tests and snapshots never depend on the screen
    /// they run on.
    @Entry var popoverAvailableHeight: CGFloat = AccountListMetrics.defaultRoom
}

/// How tall ONE presentation surface may be — the popover or the ⌥⌘U
/// window, which can open on different screens, so each owns its own
/// instance (as each owns its `AccountPinSnapshot`).
///
/// Owned by the presenter, not the view: `MenuBarController` updates it each
/// time its surface is about to show, and the hosted content, created once,
/// follows.
@MainActor
final class PopoverRoom: ObservableObject {
    @Published private(set) var height = AccountListMetrics.defaultRoom

    /// The room on the screen with this visible frame.
    func update(visibleFrame: CGRect) {
        let room = AccountListMetrics.room(visibleFrame: visibleFrame)
        if height != room { height = room }
    }
}
