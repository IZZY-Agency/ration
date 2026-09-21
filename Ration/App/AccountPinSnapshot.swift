import Combine
import Foundation

/// Capture-time ordering pin for ONE presentation surface.
///
/// Deliberately owned by the presenter rather than the view: the popover's
/// `NSHostingController` is created once and reused for every show, so
/// `.onAppear` is not a reliable per-presentation hook. Each surface owns its
/// own instance — sharing one would let presenting the popover reorder an
/// already-visible fallback window.
@MainActor
final class AccountPinSnapshot: ObservableObject {
    @Published private(set) var orderingPinByProvider: [Provider: UUID] = [:]

    func refresh(
        from activeAccounts: [UUID: ActiveUsage],
        accounts: [AccountRecord]
    ) {
        var pins: [Provider: UUID] = [:]
        for account in accounts where activeAccounts[account.id] != nil {
            // The detector yields at most one active account per provider, so
            // there is never a contest to resolve here.
            pins[account.provider] = account.id
        }
        orderingPinByProvider = pins
    }

    /// Convenience for callers that have `ActiveUsageMap.compute`'s raw inputs
    /// on hand rather than an already-computed `[UUID: ActiveUsage]` — computes
    /// and refreshes in one call. Both `captured(accounts:history:now:)` below
    /// and `MenuBarController.capturePin` route through this single method, so
    /// there is exactly one implementation of "accounts + history + now → pin
    /// state" shared by every presentation surface.
    func refresh(accounts: [AccountRecord], history: UsageHistoryStore, now: Date) {
        refresh(
            from: ActiveUsageMap.compute(accounts: accounts, history: history, now: now),
            accounts: accounts
        )
    }

    /// Builds a snapshot already captured as of `now`, for one-shot,
    /// deferred-construction call sites that have no existing instance to
    /// refresh in place — e.g. a `@StateObject` initial-value autoclosure,
    /// which SwiftUI evaluates only the first time it materializes storage for
    /// a given view identity.
    static func captured(
        accounts: [AccountRecord],
        history: UsageHistoryStore,
        now: Date
    ) -> AccountPinSnapshot {
        let snapshot = AccountPinSnapshot()
        snapshot.refresh(accounts: accounts, history: history, now: now)
        return snapshot
    }

    /// Whether a fallback-window presentation should re-capture. Pure so both
    /// directions are testable without a window: capture when the window is
    /// created or comes back from hidden, never on a plain re-focus of a window
    /// that is already visible.
    nonisolated static func shouldCapture(isNewWindow: Bool, isVisible: Bool) -> Bool {
        isNewWindow || !isVisible
    }
}
