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
/// visibility rule here — anything that isn't "is this account paused"
/// would silently change refresh/alert eligibility too. A popover-only
/// filter belongs at its own call site, not in this shared definition.
enum AccountVisibility {
    static func visible(_ accounts: [AccountRecord]) -> [AccountRecord] {
        accounts.filter { !$0.isPaused }
    }

    static func visible(_ presentations: [AccountPresentation]) -> [AccountPresentation] {
        presentations.filter { !$0.account.isPaused }
    }
}
