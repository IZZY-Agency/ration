import Foundation

/// The subscription plan behind an account. Plans of one
/// provider differ ~4× in absolute capacity, so switch advice compares
/// `headroom × capacityUnits`, not bare percentages.
enum PlanTier: String, Codable, CaseIterable, Sendable {
    case claudePro
    case claudeMax5x
    case claudeMax20x
    case chatGPTPlus
    case chatGPTPro5x
    case chatGPTPro20x

    var provider: Provider {
        switch self {
        case .claudePro, .claudeMax5x, .claudeMax20x: .claude
        case .chatGPTPlus, .chatGPTPro5x, .chatGPTPro20x: .chatGPT
        }
    }

    /// Relative capacity within a provider: Pro/Plus 1, 5x 5, 20x 20.
    var capacityUnits: Double {
        switch self {
        case .claudePro, .chatGPTPlus: 1
        case .claudeMax5x, .chatGPTPro5x: 5
        case .claudeMax20x, .chatGPTPro20x: 20
        }
    }

    /// Short uppercase tag shown next to the provider chip.
    var tag: String {
        switch self {
        case .claudePro: "PRO"
        case .claudeMax5x: "MAX 5X"
        case .claudeMax20x: "MAX 20X"
        case .chatGPTPlus: "PLUS"
        case .chatGPTPro5x: "PRO 5X"
        case .chatGPTPro20x: "PRO 20X"
        }
    }

    /// Picker / VoiceOver name.
    var displayName: String {
        switch self {
        case .claudePro: "Pro"
        case .claudeMax5x: "Max 5x"
        case .claudeMax20x: "Max 20x"
        case .chatGPTPlus: "Plus"
        case .chatGPTPro5x: "Pro 5x"
        case .chatGPTPro20x: "Pro 20x"
        }
    }

    static func options(for provider: Provider) -> [PlanTier] {
        allCases.filter { tier in tier.provider == provider }
    }

    /// Claude `GET /api/organizations` → the resolved org's `rate_limit_tier`
    /// and `capabilities` (live-verified 2026-09-24: `default_claude_max_20x`
    /// with `["chat","claude_max"]`). Nil = unknown.
    static func fromClaude(rateLimitTier: String?, capabilities: [String]) -> PlanTier? {
        guard let tier = rateLimitTier?.lowercased(), !tier.isEmpty else { return nil }
        switch tier {
        case "default_claude_max_20x": return .claudeMax20x
        case "default_claude_max_5x": return .claudeMax5x
        default: break
        }
        let isDefaultClaude: Bool = tier.hasPrefix("default_claude_")
        let mentionsMax: Bool = tier.contains("max")
        let hasMaxCapability: Bool = capabilities.contains("claude_max")
        if isDefaultClaude, !mentionsMax, !hasMaxCapability {
            return .claudePro
        }
        return nil
    }

    /// ChatGPT `wham/usage` → `plan_type` (live-verified 2026-09-24:
    /// `prolite` on a Pro 5x account). Nil = unknown.
    static func fromChatGPT(planType: String?) -> PlanTier? {
        switch planType?.lowercased() {
        case "prolite": .chatGPTPro5x
        case "pro": .chatGPTPro20x
        case "plus": .chatGPTPlus
        default: nil
        }
    }
}

/// Who set an account's plan. Detection never overwrites `.user`.
enum PlanSource: String, Codable, Sendable {
    case detected
    case user
}

/// One fetch's reading of the provider's plan field. Carried in memory on the
/// snapshot; `nil` on the snapshot = the field was not read this fetch.
enum PlanDetection: Equatable, Sendable {
    case tier(PlanTier)
    /// The provider sent a value Ration can't map.
    case unrecognized

    static func claude(rateLimitTier: String?, capabilities: [String]) -> PlanDetection? {
        guard let rateLimitTier, !rateLimitTier.isEmpty else { return nil }
        if let tier = PlanTier.fromClaude(rateLimitTier: rateLimitTier, capabilities: capabilities) {
            return .tier(tier)
        }
        PlanDetectionLog.unrecognized(provider: .claude, raw: rateLimitTier)
        return .unrecognized
    }

    static func chatGPT(planType: String?) -> PlanDetection? {
        guard let planType, !planType.isEmpty else { return nil }
        if let tier = PlanTier.fromChatGPT(planType: planType) {
            return .tier(tier)
        }
        PlanDetectionLog.unrecognized(provider: .chatGPT, raw: planType)
        return .unrecognized
    }
}

/// Notes, once per launch per provider, that a plan value could not be
/// mapped. The raw value is NEVER logged — nothing guarantees it is only a
/// plan code (it could carry a name or an email fragment); the fixed line
/// only says which provider needs a look.
enum PlanDetectionLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var logged: Set<Provider> = []
    /// Where the line goes; tests capture it.
    nonisolated(unsafe) static var emit: @Sendable (String) -> Void = { NSLog("%@", $0) }

    static func unrecognized(provider: Provider, raw _: String) {
        lock.lock()
        let isNew: Bool = logged.insert(provider).inserted
        lock.unlock()
        if isNew {
            emit("Ration: unrecognized \(provider.rawValue) plan value")
        }
    }

    /// Test-only: forget which providers were already noted.
    static func resetForTesting() {
        lock.lock()
        logged.removeAll()
        lock.unlock()
    }
}

extension AccountRecord {
    /// The plan, when it belongs to this account's provider.
    var effectivePlan: PlanTier? {
        guard let plan, plan.provider == provider else { return nil }
        return plan
    }

    /// Applies one fetch's detection. A `.user` choice is never touched; an
    /// unrecognized value clears a previously detected plan (the plan changed
    /// to something Ration can't size, so the old capacity would mislead).
    func applyingDetectedPlan(_ detection: PlanDetection) -> AccountRecord {
        guard planSource != .user else { return self }
        var updated = self
        switch detection {
        case let .tier(tier):
            guard tier.provider == provider else { return self }
            updated.plan = tier
            updated.planSource = .detected
        case .unrecognized:
            updated.plan = nil
            updated.planSource = nil
        }
        return updated
    }
}

/// The add-account "Which plan is this?" step: shown after a
/// successful sign-in only for providers with plans, and only while the plan
/// is unknown or the billing day is unset. Both answers are skippable.
enum PlanStep {
    static func isNeeded(for account: AccountRecord) -> Bool {
        guard !PlanTier.options(for: account.provider).isEmpty else { return false }
        return account.effectivePlan == nil || account.billingRenewalDay == nil
    }
}

/// The Settings plan picker's rows and the cards' tag, derived purely so the
/// views stay thin. The picker selection is a string: `automatic` or a
/// `PlanTier` raw value.
enum PlanChoice {
    static let automatic = "auto"

    static func selection(for account: AccountRecord) -> String {
        guard account.planSource == .user, let plan = account.effectivePlan else { return automatic }
        return plan.rawValue
    }

    /// The "let Ration decide" option, naming the detected plan (plan names
    /// are never translated).
    static func automaticTitle(for account: AccountRecord, locale: Locale = .current) -> String {
        switch account.planSource {
        case .user:
            return LocalizedStringResource.planAutomatic.string(in: locale)
        case .detected:
            guard let plan = account.effectivePlan else {
                return LocalizedStringResource.planAutomaticNotDetected.string(in: locale)
            }
            return LocalizedStringResource.planAutomaticDetected(plan.displayName).string(in: locale)
        case nil:
            return LocalizedStringResource.planAutomaticNotDetected.string(in: locale)
        }
    }

    static func plan(forSelection selection: String) -> PlanTier? {
        PlanTier(rawValue: selection)
    }

    /// Card / Focus tag; nil = show nothing.
    static func tag(for account: AccountRecord) -> String? {
        account.effectivePlan?.tag
    }
}
