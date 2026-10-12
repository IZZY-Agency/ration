import Foundation

/// The Codex row on a ChatGPT card (spec §4.4): the CODEX tag on the account
/// Codex uses now, SWITCH on the other linked, unpaused ones.
enum CodexCardState: Equatable, Sendable {
    case none, current, switching
    /// `sameWorkspace`: the card's login is another seat of the workspace
    /// Codex is on now — a running session may follow it instead of
    /// refusing (spec §1, §4.5), and the button says so.
    case canSwitch(sameWorkspace: Bool)
}

/// The Focus line (spec §4.4): "Codex on <account>", with SWITCH TO for the
/// switchable account with the most room.
struct CodexFocusLine: Equatable, Sendable {
    struct Target: Equatable, Sendable {
        let accountID: UUID
        let label: String
        /// Another seat of the workspace Codex is on.
        let sameWorkspace: Bool

        init(accountID: UUID, label: String, sameWorkspace: Bool = false) {
            self.accountID = accountID
            self.label = label
            self.sameWorkspace = sameWorkspace
        }
    }

    let currentLabel: String
    /// nil when none can take over.
    let target: Target?
}

/// The one Codex line in the popover (spec §4.6, §5): what happened, whatever
/// the notification settings. Pure.
enum CodexStatusLine: Equatable, Sendable {
    case needsAttention
    case paused
    case failed
    case noRoom
    case waiting
    /// "Sign in to <account> in Codex, then Remember again": Codex left a
    /// login right after Ration switched to it (spec §5).
    case stale(account: String)
    /// "Codex's sign-in file mixes two accounts — run codex login" (spec §2).
    case damaged
    case rememberPrompt(email: String)
    /// Its copy also says: restart running Codex sessions. Not `verified`:
    /// Codex refreshed the sign-in meanwhile. `sameWorkspace`:
    /// another seat of the workspace Codex was on — running sessions may
    /// follow it; that copy wins over the unverified one, whose
    /// refresh was then likely such a session.
    case switched(to: String, automatic: Bool, verified: Bool = true, sameWorkspace: Bool = false)

    /// A switch is news for an hour, a failure for a day.
    static let switchShownFor: TimeInterval = 3_600
    static let failureShownFor: TimeInterval = 86_400

    /// Precedence: needs attention, damaged, stale within a day, paused, a
    /// failure or conflict within a day, no room, waiting, the Remember
    /// prompt, a switch within an hour. Damaged and stale pause automatic
    /// switching themselves: their cause is what the user must see. `label`
    /// turns a login id into the name the user knows.
    static func make(state: CodexState, rememberPrompt: String?, label: (String) -> String, now: Date) -> CodexStatusLine? {
        switch state.status {
        case .needsAttention: return .needsAttention
        case .damaged: return .damaged
        case .stale(let at, let login) where now.timeIntervalSince(at) <= failureShownFor:
            return .stale(account: label(login))
        default: break
        }
        if state.autoSwitchPaused { return .paused }
        switch state.status {
        case .failed(let at), .conflict(let at):
            if now.timeIntervalSince(at) <= failureShownFor { return .failed }
        case .noRoom:
            return .noRoom
        case .waiting:
            return .waiting
        default:
            break
        }
        if let rememberPrompt { return .rememberPrompt(email: rememberPrompt) }
        if case .switched(let at, _, let to, let automatic, let verified, let sameWorkspace) = state.status,
           now.timeIntervalSince(at) <= switchShownFor {
            return .switched(to: label(to), automatic: automatic, verified: verified, sameWorkspace: sameWorkspace)
        }
        return nil
    }
}
