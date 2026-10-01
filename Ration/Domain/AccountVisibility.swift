import Foundation

/// Single definition of "active (non-paused) accounts", used for two
/// distinct roles: (a) the POPOVER surfaces — cards, in-use detection,
/// provider pinning — via `visibleAccounts`/`visible(_:)`, and (b) refresh
/// and alert eligibility via `AppModel.refreshableAccounts`, which also
/// filters through this helper so a paused account gets no fetch and no
/// alert evaluation (dormancy). Paused accounts stay visible in Settings and
/// History, which read `accounts`/`presentations` directly instead.
///
/// Because dormancy (b) depends on this helper, NEVER add a UI-only
/// visibility rule here — anything that isn't dormancy would silently change
/// refresh/alert eligibility too. A popover-only filter belongs at its own
/// call site, not in this shared definition.
///
/// Dormant: paused, or of a provider switched off in this build
/// (`Provider.isOffered`) — no fetch, no alert, no card or gauge. Settings
/// hides a switched-off provider's accounts itself (`offered(_:)`); their
/// stores and web profiles stay, so turning the provider back on restores them.
enum AccountVisibility {
    static func visible(_ accounts: [AccountRecord]) -> [AccountRecord] {
        accounts.filter { !$0.isPaused && $0.provider.isOffered }
    }

    static func visible(_ presentations: [AccountPresentation]) -> [AccountPresentation] {
        presentations.filter { !$0.account.isPaused && $0.account.provider.isOffered }
    }

    /// Settings' lists: paused accounts included, switched-off providers not.
    static func offered(_ presentations: [AccountPresentation]) -> [AccountPresentation] {
        presentations.filter { $0.account.provider.isOffered }
    }
}
