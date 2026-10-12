import Foundation

/// What the popover and Settings show whatever the notification settings
/// (spec §4.6, §5): the last switch, a failure, a pause, a needs-attention.
enum CodexStatus: Codable, Equatable, Sendable {
    /// `verified` false: Codex refreshed the target meanwhile, so the file
    /// holds its newer copy, not Ration's bytes. `sameWorkspace`:
    /// `to` is another seat of `from`'s workspace, which running sessions
    /// may follow (spec §1, §4.5).
    case switched(at: Date, from: String, to: String, automatic: Bool, verified: Bool = true, sameWorkspace: Bool = false)
    case failed(at: Date)
    case conflict(at: Date)
    case needsAttention(at: Date)
    case noRoom(at: Date)
    case waiting(at: Date)
    case paused(at: Date)
    /// Codex was seen on another login within 10 minutes of Ration's switch to
    /// `login`: the remembered copy's refresh token is probably dead (spec §5).
    case stale(at: Date, login: String)
    /// The file parsed as a mix of two accounts (spec §2): run `codex login`.
    case damaged(at: Date)
}

/// The feature's own state, `codex-switch.json` (no secrets: those live only
/// in Keychain items). Every key is a login id (`CodexLogin.id`, spec §4.1).
/// Decoded field by field, so a field this build cannot read falls back alone.
struct CodexState: Codable, Equatable, Sendable {
    /// Login id → the Ration ChatGPT account it belongs to.
    var links: [String: UUID] = [:]
    /// Logins whose "Remember?" prompt the user dismissed.
    var dismissedPrompts: [String] = []
    /// Logins the user set to None in Settings: never linked automatically
    /// until the user links them again.
    var keptUnlinked: [String] = []
    var autoSwitchEnabled = false
    /// Weekly only for Codex (spec §4.5); the type is the shared rule's.
    var rule = ClaudeCodeAutoSwitch.Rule()
    /// Set by a failed, conflicting or damaged automatic switch; cleared by Resume.
    var autoSwitchPaused = false
    var notify = true
    var status: CodexStatus?
    /// The candidate set last told "no room", so it is told once.
    var noRoomNotified: [String]?
    /// The switch Ration made last (login id, time), to recognise a dead
    /// remembered login when Codex leaves it soon after (spec §4.2, §5).
    var lastSwitchTo: String?
    var lastSwitchAt: Date?
    /// The user confirmed that Codex uses its default file (no `CODEX_HOME`,
    /// no keyring store) — required before automatic switching (spec §4.2).
    var configurationAcknowledged = false
    /// Logins Codex left within 10 minutes of Ration's switch to them (spec
    /// §5): their copy is probably dead. Never an automatic or Focus target
    /// until remembered again; by hand only.
    var staleLogins: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey {
        case links, dismissedPrompts, keptUnlinked, autoSwitchEnabled, rule, autoSwitchPaused, notify, status, noRoomNotified
        case lastSwitchTo, lastSwitchAt, configurationAcknowledged, staleLogins
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        links = (try? container.decodeIfPresent([String: UUID].self, forKey: .links)) ?? [:]
        dismissedPrompts = (try? container.decodeIfPresent([String].self, forKey: .dismissedPrompts)) ?? []
        keptUnlinked = (try? container.decodeIfPresent([String].self, forKey: .keptUnlinked)) ?? []
        autoSwitchEnabled = (try? container.decodeIfPresent(Bool.self, forKey: .autoSwitchEnabled)) ?? false
        rule = (try? container.decodeIfPresent(ClaudeCodeAutoSwitch.Rule.self, forKey: .rule)) ?? ClaudeCodeAutoSwitch.Rule()
        autoSwitchPaused = (try? container.decodeIfPresent(Bool.self, forKey: .autoSwitchPaused)) ?? false
        notify = (try? container.decodeIfPresent(Bool.self, forKey: .notify)) ?? true
        status = try? container.decodeIfPresent(CodexStatus.self, forKey: .status)
        noRoomNotified = try? container.decodeIfPresent([String].self, forKey: .noRoomNotified)
        lastSwitchTo = try? container.decodeIfPresent(String.self, forKey: .lastSwitchTo)
        lastSwitchAt = try? container.decodeIfPresent(Date.self, forKey: .lastSwitchAt)
        configurationAcknowledged = (try? container.decodeIfPresent(Bool.self, forKey: .configurationAcknowledged)) ?? false
        staleLogins = (try? container.decodeIfPresent([String].self, forKey: .staleLogins)) ?? []
    }
}

/// One switch Ration made (`codex-switches.json`): who, when, by hand or by
/// rule. Login ids only; named in the privacy wording (spec §4.7).
struct CodexSwitchLogEntry: Codable, Equatable, Sendable {
    let at: Date
    let from: String
    let to: String
    let automatic: Bool
    let rule: ClaudeCodeAutoSwitch.Rule?

    static let limit = 500
    static let fileName = "codex-switches.json"

    static func appending(_ entry: CodexSwitchLogEntry, to log: [CodexSwitchLogEntry]) -> [CodexSwitchLogEntry] {
        Array((log + [entry]).suffix(limit))
    }
}
