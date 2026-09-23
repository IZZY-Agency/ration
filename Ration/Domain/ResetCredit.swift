import Foundation

/// One usage-limit reset the provider has granted the account (Claude
/// `cedar_ember.grants[]`, Codex `wham/rate-limit-reset-credits`). Ration only
/// SHOWS these — redeeming one is a write to the user's account and is out of
/// scope.
struct ResetCredit: Codable, Equatable, Sendable {
    /// Provider-issued id — the dedupe key for alerts.
    let id: String
    /// Provider copy, localised to the account's UI language. Never shown in
    /// redacted notifications.
    let title: String?
    /// Claude `resets_left`; Codex is one credit per entry.
    let count: Int
    let expiresAt: Date
    /// `nil` when the provider doesn't say.
    let usableNow: Bool?
}

/// A reset list as READ by one fetch.
///
/// `fetchedAt` equals the `UsageSnapshot.fetchedAt` of the fetch that read it.
/// A later snapshot that could not read resets carries this value forward
/// unchanged (see `UsageSnapshotStore.save`), so `fetchedAt != snapshot.fetchedAt`
/// is how alerts know the list is not fresh evidence.
struct ResetCredits: Codable, Equatable, Sendable {
    let fetchedAt: Date
    let items: [ResetCredit]
    /// `false` when at least one provider item was malformed and skipped — the
    /// list is then not authoritative about ABSENCE, so alert memory is not
    /// pruned from it.
    let complete: Bool

    /// Display/evaluation filter: local expiry, independent of what the
    /// provider last said.
    func unexpired(at now: Date) -> [ResetCredit] {
        items.filter { $0.expiresAt > now }
    }
}
