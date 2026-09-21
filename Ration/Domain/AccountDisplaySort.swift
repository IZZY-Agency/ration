import Foundation

/// Pure, display-only ordering of account presentations. When enabled, groups
/// by provider (in `Provider.allCases` order) and sorts each group ascending by
/// each account's **soonest upcoming reset among its own window kinds** (nil
/// last), tie-breaking on the persisted `displayOrder` so equal/nil resets keep
/// their manual order. Never mutates persisted order.
///
/// Ranking on the account's own kinds rather than specifically `weekly`
/// matters now that providers differ in which windows they even have: Cursor
/// exposes only monthly pools, so reading `snapshot.weekly` would see nil for
/// every Cursor account and silently collapse the whole group to
/// `displayOrder`.
enum AccountDisplaySort {
    static func sorted(
        _ presentations: [AccountPresentation],
        sortByWeeklyReset: Bool
    ) -> [AccountPresentation] {
        guard sortByWeeklyReset else { return presentations }

        let providerRank = Dictionary(
            uniqueKeysWithValues: Provider.allCases.enumerated().map { ($1, $0) }
        )

        return presentations.enumerated().sorted { lhs, rhs in
            let a = lhs.element, b = rhs.element
            let ra = providerRank[a.account.provider] ?? Int.max
            let rb = providerRank[b.account.provider] ?? Int.max
            if ra != rb { return ra < rb }

            let wa = soonestReset(a)
            let wb = soonestReset(b)
            switch (wa, wb) {
            case let (l?, r?) where l != r: return l < r
            case (nil, .some): return false            // nil sinks after a real reset
            case (.some, nil): return true
            default: break                             // both nil, or equal → tie-break
            }
            // Stable tie-break: persisted displayOrder, then original index.
            if a.account.displayOrder != b.account.displayOrder {
                return a.account.displayOrder < b.account.displayOrder
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    /// The earliest reset this account has across every window it carries.
    /// Derived from `allWindows`, so a provider whose kinds change — or a new
    /// provider entirely — is ranked correctly without touching this file.
    private static func soonestReset(_ presentation: AccountPresentation) -> Date? {
        presentation.snapshot?.allWindows.compactMap { $0.window.resetsAt }.min()
    }
}
