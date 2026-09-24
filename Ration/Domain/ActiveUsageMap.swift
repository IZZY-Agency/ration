import Foundation

/// Single source of truth for building the active-usage maps from the history
/// store, so the popover, Settings, and menu bar never diverge on the rules.
enum ActiveUsageMap {
    /// One winner per provider ("which account am I on") — the popover pill,
    /// Settings marker, and pin capture.
    @MainActor
    static func compute(accounts: [AccountRecord], history: UsageHistoryStore, now: Date) -> [UUID: ActiveUsage] {
        ActiveUsageDetector.mostActive(
            accounts: accounts,
            fiveHourSamples: samples(.fiveHour, accounts: accounts, history: history),
            weeklySamples: samples(.weekly, accounts: accounts, history: history),
            now: now
        )
    }

    /// Every burning account, un-deduped — the menu-bar gauges, where two
    /// same-provider accounts in parallel use each get their own dot.
    ///
    /// `snapshots`, when given, reads history as it WILL be once those
    /// snapshots are recorded (`UsageHistoryStore.rawSamples(…including:)`),
    /// for a pass that runs between a snapshot's save and its `record` —
    /// switch advice. Callers without it (the menu-bar dot) may lag advice by
    /// one pass: they see the activity once `record` has run.
    @MainActor
    static func computePerAccount(
        accounts: [AccountRecord],
        history: UsageHistoryStore,
        now: Date,
        including snapshots: [UUID: UsageSnapshot]? = nil
    ) -> [UUID: ActiveUsage] {
        ActiveUsageDetector.perAccount(
            accounts: accounts,
            fiveHourSamples: samples(.fiveHour, accounts: accounts, history: history, including: snapshots),
            weeklySamples: samples(.weekly, accounts: accounts, history: history, including: snapshots),
            now: now
        )
    }

    @MainActor
    private static func samples(
        _ kind: UsageWindowKind,
        accounts: [AccountRecord],
        history: UsageHistoryStore,
        including snapshots: [UUID: UsageSnapshot]? = nil
    ) -> [UUID: [UsageHistorySample]] {
        var result: [UUID: [UsageHistorySample]] = [:]
        for account in accounts {
            if let snapshots {
                result[account.id] = history.rawSamples(
                    accountID: account.id,
                    kind: kind,
                    provider: account.provider,
                    including: snapshots[account.id]
                )
            } else {
                result[account.id] = history.rawSamples(accountID: account.id, kind: kind)
            }
        }
        return result
    }
}
