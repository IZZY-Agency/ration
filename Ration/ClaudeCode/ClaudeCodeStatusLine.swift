import Foundation

/// The one line under the Claude section header in the popover (spec §4.6):
/// what happened, whatever the notification settings. Pure.
enum ClaudeCodeStatusLine: Equatable, Sendable {
    case needsAttention
    case paused
    case failed
    case noRoom
    case waiting
    case rememberPrompt(organization: String)
    case switched(to: String, automatic: Bool)

    /// A switch is news for an hour, a failure for a day.
    static let switchShownFor: TimeInterval = 3_600
    static let failureShownFor: TimeInterval = 86_400

    static func make(state: ClaudeCodeState, rememberPrompt: String?, label: (String) -> String, now: Date) -> ClaudeCodeStatusLine? {
        if case .needsAttention = state.status { return .needsAttention }
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
        if let rememberPrompt { return .rememberPrompt(organization: rememberPrompt) }
        if case .switched(let at, _, let to, let automatic) = state.status, now.timeIntervalSince(at) <= switchShownFor {
            return .switched(to: label(to), automatic: automatic)
        }
        return nil
    }
}
