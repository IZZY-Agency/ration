import Foundation

/// What the popover and Settings show whatever the notification settings
/// (spec §4.6): the last switch, a failure, a pause, a needs-attention.
enum ClaudeCodeStatus: Codable, Equatable, Sendable {
    case switched(at: Date, from: String, to: String, automatic: Bool)
    case failed(at: Date)
    case conflict(at: Date)
    case needsAttention(at: Date)
    case noRoom(at: Date)
    case waiting(at: Date)
    case paused(at: Date)
}

/// The feature's own state, `claude-code-switch.json` (plan ruling: kept out
/// of `AppSettings`). No token: those live only in Keychain items.
struct ClaudeCodeState: Codable, Equatable, Sendable {
    /// Claude account uuid → the Ration account it belongs to.
    var links: [String: UUID] = [:]
    /// Sign-ins whose "Remember?" prompt the user dismissed.
    var dismissedPrompts: [String] = []
    /// Sign-ins the user set to None in Settings: never linked automatically
    /// (spec §4.2) until the user links them again.
    var keptUnlinked: [String] = []
    var autoSwitchEnabled = false
    var rule = ClaudeCodeAutoSwitch.Rule()
    /// Set by a failed or conflicting automatic switch; cleared by Resume.
    var autoSwitchPaused = false
    var notify = true
    var status: ClaudeCodeStatus?
    /// The candidate set last told "no room", so it is told once.
    var noRoomNotified: [String]?

    init() {}

    enum CodingKeys: String, CodingKey {
        case links, dismissedPrompts, keptUnlinked, autoSwitchEnabled, rule, autoSwitchPaused, notify, status, noRoomNotified
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
        status = try? container.decodeIfPresent(ClaudeCodeStatus.self, forKey: .status)
        noRoomNotified = try? container.decodeIfPresent([String].self, forKey: .noRoomNotified)
    }
}

/// One switch Ration made (`claude-code-switches.json`), for token burn: who,
/// when, by hand or by rule. Account uuids only.
struct ClaudeCodeSwitchLogEntry: Codable, Equatable, Sendable {
    let at: Date
    let from: String
    let to: String
    let automatic: Bool
    let rule: ClaudeCodeAutoSwitch.Rule?

    static let limit = 500
    static let fileName = "claude-code-switches.json"

    static func appending(_ entry: ClaudeCodeSwitchLogEntry, to log: [ClaudeCodeSwitchLogEntry]) -> [ClaudeCodeSwitchLogEntry] {
        Array((log + [entry]).suffix(limit))
    }
}
