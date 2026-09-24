import Foundation

/// The popover header's status word — whether the numbers on screen still
/// describe the present. "Truth over reassurance": the header may say LIVE
/// only while every active account's data is current evidence.
///
/// Derived from snapshot age through `UsageEvidence` (the same age bound the
/// attention drop and warm-up banner use), so the header and the drop agree
/// about what is current. `AccountViewState.loading` is deliberately NOT a
/// signal: every poll passes through it, and gating on it would flicker the
/// header on each refresh. States that persist across polls — the account
/// needs a sign-in, is rate-limited, changed shape, or is unavailable — do
/// count as not current even while their last snapshot is young.
enum HeaderFreshness: Equatable, Sendable {
    case live
    case stale(count: Int)
    case offline

    /// `nil` when there is nothing to vouch for: none connected, all paused,
    /// or every active account still on its first fetch. An account whose
    /// fetch FAILED counts even with no snapshot cached.
    ///
    /// OFFLINE is reserved for what the word means: several accounts, none
    /// current, and every one of them simply aged out (connectivity or sleep).
    /// A single account, or any account that needs a sign-in / is rate-limited
    /// / changed shape / is unavailable, reads as STALE instead — the app is
    /// not offline, those accounts have a problem of their own.
    static func make(presentations: [AccountPresentation], now: Date) -> HeaderFreshness? {
        let judged = AccountVisibility.visible(presentations).compactMap { presentation -> Judgement? in
            judge(snapshot: presentation.snapshot, state: presentation.state, now: now)
        }
        guard !judged.isEmpty else { return nil }
        let staleCount = judged.filter { $0 != .current }.count
        if staleCount == 0 { return .live }
        if judged.count > 1, judged.allSatisfy({ $0 == .agedOut }) { return .offline }
        return .stale(count: staleCount)
    }

    private enum Judgement: Equatable {
        case current
        /// Too old — the app has not been able to look (offline, asleep).
        case agedOut
        /// A problem that persists across polls regardless of connectivity.
        case accountProblem
    }

    /// `nil` = not counted: an account with no snapshot that is still
    /// awaiting its first fetch. A persistent failure state is judged BEFORE
    /// a snapshot is required — the coordinator reports a failed first fetch
    /// as `.unavailable` (or reauth / rate-limited / changed shape) with
    /// nothing cached, and that account must not vanish from the count.
    private static func judge(snapshot: UsageSnapshot?, state: AccountViewState, now: Date) -> Judgement? {
        switch state {
        case .reauthenticationRequired, .rateLimited, .integrationChanged, .unavailable:
            return .accountProblem
        case .stale where snapshot == nil:
            // A failed fetch with nothing cached never aged out — it never
            // had data. A problem, not OFFLINE.
            return .accountProblem
        case .loading, .current, .stale:
            guard let snapshot else { return nil }
            // Age alone, no window boundary: this asks whether the account's
            // data is fresh, not whether one window has since reset.
            return UsageEvidence.isCurrent(snapshot: snapshot, windowResetsAt: nil, now: now)
                ? .current
                : .agedOut
        }
    }

    var text: String {
        switch self {
        case .live: "LIVE"
        case .stale(let count): "STALE · \(count)"
        case .offline: "OFFLINE"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .live: "Live"
        case .stale(let count): count == 1 ? "1 account stale" : "\(count) accounts stale"
        case .offline: "Offline"
        }
    }
}
