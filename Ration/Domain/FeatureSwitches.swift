import Foundation

/// The four global feature switches (Settings → General → Features), all ON by
/// default. Presentation and gating only: fetching, alert evaluation, dedupe
/// and reset-credit bookkeeping keep running while a switch is off, so turning
/// it back on shows current state instead of replaying a backlog.
struct FeatureSwitches: Equatable, Sendable {
    /// Reset credits: card line, account-pane list, Alerts rows, reset alerts.
    var resets: Bool
    /// Switch suggestions as the user chose them (see `switchAdviceEffective`).
    var switchAdvice: Bool
    /// Claude warm-up (auto-start). Off → no account warms up.
    var warmUp: Bool
    /// In-use detection: IN USE pill/frame/tint, menu-bar dots, Focus hero pick.
    var inUse: Bool

    static let allOn = FeatureSwitches(resets: true, switchAdvice: true, warmUp: true, inUse: true)

    /// Switch advice is built on in-use detection (its `from` account is the
    /// in-use one), so it is live only when both switches are on.
    var switchAdviceEffective: Bool { switchAdvice && inUse }
}

/// One global switch, for the Settings → General → Features rows.
enum FeatureSwitch: String, CaseIterable, Identifiable, Sendable {
    case resets
    case switchAdvice
    case warmUp
    case inUse

    var id: String { rawValue }

    var title: String {
        switch self {
        case .resets: "Resets"
        case .switchAdvice: "Switch suggestions"
        case .warmUp: "Claude warm-up"
        case .inUse: "In-use detection"
        }
    }

    var summary: String {
        switch self {
        case .resets: "Shows usage-limit resets on cards and in account settings, and alerts about them."
        case .switchAdvice: "Suggests which account to move to when the one you're on nears its limit."
        case .warmUp: "Starts Claude 5-hour windows automatically for accounts with Auto-start on."
        case .inUse: "Marks the account you're working in: IN USE tags, menu-bar dots, Focus hero."
        }
    }

    /// Shown under a switch that cannot take effect on its own.
    static let switchAdviceNeedsInUseNote = "Needs in-use detection"
    /// Shown under each account's Auto-start toggle while warm-up is off.
    static let warmUpOffNote = "Warm-up is off in General"

    func isOn(in features: FeatureSwitches) -> Bool {
        switch self {
        case .resets: features.resets
        case .switchAdvice: features.switchAdvice
        case .warmUp: features.warmUp
        case .inUse: features.inUse
        }
    }

    /// Whether the row's toggle can be changed. Switch suggestions are built
    /// on in-use detection, so their toggle is locked while it is off (the
    /// stored choice is kept for when it comes back).
    func isAvailable(in features: FeatureSwitches) -> Bool {
        self == .switchAdvice ? features.inUse : true
    }
}
