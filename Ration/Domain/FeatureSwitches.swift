import Foundation

/// The global feature switches (Settings → General → Features), all ON by
/// default. Presentation and gating only: fetching, alert evaluation, dedupe
/// and reset-credit bookkeeping keep running while a switch is off, so turning
/// it back on shows current state instead of replaying a backlog.
///
/// `resets` and `usageCredits` are no longer switches of their own: since
/// 2026-10-01 each provider has its own (`ProviderShow`), and these two only
/// supply the default for a provider with no choice yet.
struct FeatureSwitches: Equatable, Sendable {
    /// Legacy default for every provider's Resets switch.
    var resets: Bool
    /// Switch suggestions as the user chose them (see `switchAdviceEffective`).
    var switchAdvice: Bool
    /// Claude warm-up (auto-start). Off → no account warms up.
    var warmUp: Bool
    /// In-use detection: IN USE pill/frame/tint, menu-bar dots, Focus hero pick.
    var inUse: Bool
    /// Legacy default for every provider's Credits switch.
    var usageCredits: Bool = true
    /// Keep the Mac from idle sleep while an account is in use (on the power
    /// adapter). The one switch that starts OFF: it changes the Mac's
    /// behaviour beyond the app.
    var keepAwake: Bool = false

    /// Every switch at its default — all on, keep-awake off.
    static let allOn = FeatureSwitches(resets: true, switchAdvice: true, warmUp: true, inUse: true, usageCredits: true)

    /// Switch advice is built on in-use detection (its `from` account is the
    /// in-use one), so it is live only when both switches are on.
    var switchAdviceEffective: Bool { switchAdvice && inUse }

    /// The automatic keep-awake hold follows the IN USE phase, so it is live
    /// only when both switches are on.
    var keepAwakeEffective: Bool { keepAwake && inUse }
}

/// One global switch, for the Settings → General → Features rows. Credits
/// and resets are per provider (`ProviderShowItem`).
enum FeatureSwitch: String, CaseIterable, Identifiable, Sendable {
    case switchAdvice
    case warmUp
    case inUse
    case keepAwake

    var id: String { rawValue }

    var title: String { title(locale: .current) }

    func title(locale: Locale) -> String {
        let resource: LocalizedStringResource = switch self {
        case .switchAdvice: .featureSwitchTitleSwitchAdvice
        case .warmUp: .featureSwitchTitleWarmUp
        case .inUse: .featureSwitchTitleInUse
        case .keepAwake: .featureSwitchTitleKeepAwake
        }
        return resource.string(in: locale)
    }

    var summary: String { summary(locale: .current) }

    func summary(locale: Locale) -> String {
        let resource: LocalizedStringResource = switch self {
        case .switchAdvice: .featureSwitchSummarySwitchAdvice
        case .warmUp: .featureSwitchSummaryWarmUp
        case .inUse: .featureSwitchSummaryInUse
        case .keepAwake: .featureSwitchSummaryKeepAwake
        }
        return resource.string(in: locale)
    }

    /// Shown under a switch built on in-use detection while that is off
    /// (switch suggestions, keep awake).
    static var needsInUseNote: String { needsInUseNote(locale: .current) }

    static func needsInUseNote(locale: Locale) -> String {
        LocalizedStringResource.featureSwitchNoteSwitchAdviceNeedsInUse.string(in: locale)
    }

    /// Shown under each account's Auto-start toggle while warm-up is off.
    static var warmUpOffNote: String { warmUpOffNote(locale: .current) }

    static func warmUpOffNote(locale: Locale) -> String {
        LocalizedStringResource.featureSwitchNoteWarmUpOff.string(in: locale)
    }

    func isOn(in features: FeatureSwitches) -> Bool {
        switch self {
        case .switchAdvice: features.switchAdvice
        case .warmUp: features.warmUp
        case .inUse: features.inUse
        case .keepAwake: features.keepAwake
        }
    }

    /// Whether the row's toggle can be changed. Switch suggestions and keep
    /// awake are built on in-use detection, so their toggles are locked while
    /// it is off (the stored choice is kept for when it comes back).
    func isAvailable(in features: FeatureSwitches) -> Bool {
        switch self {
        case .switchAdvice, .keepAwake: features.inUse
        case .warmUp, .inUse: true
        }
    }
}
