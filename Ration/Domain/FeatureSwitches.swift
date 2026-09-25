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

    var title: String { title(locale: .current) }

    func title(locale: Locale) -> String {
        let resource: LocalizedStringResource = switch self {
        case .resets: .featureSwitchTitleResets
        case .switchAdvice: .featureSwitchTitleSwitchAdvice
        case .warmUp: .featureSwitchTitleWarmUp
        case .inUse: .featureSwitchTitleInUse
        }
        return resource.string(in: locale)
    }

    var summary: String { summary(locale: .current) }

    func summary(locale: Locale) -> String {
        let resource: LocalizedStringResource = switch self {
        case .resets: .featureSwitchSummaryResets
        case .switchAdvice: .featureSwitchSummarySwitchAdvice
        case .warmUp: .featureSwitchSummaryWarmUp
        case .inUse: .featureSwitchSummaryInUse
        }
        return resource.string(in: locale)
    }

    /// Shown under a switch that cannot take effect on its own.
    static var switchAdviceNeedsInUseNote: String { switchAdviceNeedsInUseNote(locale: .current) }

    static func switchAdviceNeedsInUseNote(locale: Locale) -> String {
        LocalizedStringResource.featureSwitchNoteSwitchAdviceNeedsInUse.string(in: locale)
    }

    /// Shown under each account's Auto-start toggle while warm-up is off.
    static var warmUpOffNote: String { warmUpOffNote(locale: .current) }

    static func warmUpOffNote(locale: Locale) -> String {
        LocalizedStringResource.featureSwitchNoteWarmUpOff.string(in: locale)
    }

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
