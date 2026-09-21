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
    @MainActor
    static func computePerAccount(accounts: [AccountRecord], history: UsageHistoryStore, now: Date) -> [UUID: ActiveUsage] {
        ActiveUsageDetector.perAccount(
            accounts: accounts,
            fiveHourSamples: samples(.fiveHour, accounts: accounts, history: history),
            weeklySamples: samples(.weekly, accounts: accounts, history: history),
            now: now
        )
    }

    @MainActor
    private static func samples(
        _ kind: UsageWindowKind,
        accounts: [AccountRecord],
        history: UsageHistoryStore
    ) -> [UUID: [UsageHistorySample]] {
        Dictionary(uniqueKeysWithValues: accounts.map {
            ($0.id, history.rawSamples(accountID: $0.id, kind: kind))
        })
    }
}
