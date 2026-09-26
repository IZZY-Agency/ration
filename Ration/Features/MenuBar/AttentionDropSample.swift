import Foundation

/// The rows of the "Show test drop" diagnostic (Settings › General ›
/// Diagnostics), which exists so live placement checks can be walked on
/// demand instead of waiting for a real threshold crossing.
///
/// Every row is fake and says so: the account label is the catalog's
/// "SAMPLE" wording, and the account ids below belong to no real account, so
/// even a code path that forgot it was handling a test row could not touch a
/// real account's alert state (`AppModel.dismissAttentionRows` skips ids it
/// does not know).
enum AttentionDropSample {
    static let claudeAccountID = UUID(uuidString: "00000000-0000-4000-8000-00000000D901")!
    static let chatGPTAccountID = UUID(uuidString: "00000000-0000-4000-8000-00000000D902")!
    static let cursorAccountID = UUID(uuidString: "00000000-0000-4000-8000-00000000D903")!

    /// All three row shapes the drop draws for limits: a critical rate
    /// window, a warning rate window, and Cursor spend.
    static func rows(now: Date, locale: Locale = .current) -> [AttentionRow] {
        let label = LocalizedStringResource.dropTestSampleAccount.string(in: locale)
        let critical = AttentionRow(
            accountID: claudeAccountID,
            accountLabel: label,
            provider: .claude,
            subject: .window(.fiveHour),
            tier: .critical,
            usedPercent: 92,
            spentCents: nil,
            thresholdPercent: 90,
            thresholdCents: nil,
            resetsAt: now.addingTimeInterval(100 * 60),
            resetCount: nil,
            resetCreditIDs: []
        )
        let warning = AttentionRow(
            accountID: chatGPTAccountID,
            accountLabel: label,
            provider: .chatGPT,
            subject: .window(.weekly),
            tier: .warning,
            usedPercent: 78,
            spentCents: nil,
            thresholdPercent: 75,
            thresholdCents: nil,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600),
            resetCount: nil,
            resetCreditIDs: []
        )
        let spend = AttentionRow(
            accountID: cursorAccountID,
            accountLabel: label,
            provider: .cursor,
            subject: .cursorSpend,
            tier: .warning,
            usedPercent: nil,
            spentCents: 4_200,
            thresholdPercent: nil,
            thresholdCents: 4_000,
            resetsAt: now.addingTimeInterval(9 * 24 * 3600),
            resetCount: nil,
            resetCreditIDs: []
        )
        return [critical, warning, spend]
    }

    static let accountIDs: Set<UUID> = [claudeAccountID, chatGPTAccountID, cursorAccountID]
}
