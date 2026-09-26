import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case claude
    case chatGPT = "chatgpt"
    case cursor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claude:
            "Claude"
        case .chatGPT:
            "ChatGPT"
        case .cursor:
            "Cursor"
        }
    }

    /// The provider's web address, as a person types it ("claude.ai") — the
    /// host of every adapter's `signInURL`.
    var appHost: String {
        switch self {
        case .claude:
            "claude.ai"
        case .chatGPT:
            "chatgpt.com"
        case .cursor:
            "cursor.com"
        }
    }

    func matchesAppHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == appHost || host.hasSuffix(".\(appHost)")
    }

    /// The exact HTTPS origin the app expects the account's web view to be on
    /// when it evaluates a credentialed request. Enforced inside the injected
    /// scripts so a mid-flight navigation to a foreign origin cannot receive a
    /// credentialed request meant for this provider.
    var webOrigin: String {
        switch self {
        case .claude:
            "https://claude.ai"
        case .chatGPT:
            "https://chatgpt.com"
        case .cursor:
            "https://cursor.com"
        }
    }
}

struct AccountRecord: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var provider: Provider
    var label: String
    let webProfileID: UUID
    var displayOrder: Int
    let createdAt: Date

    // Auto-start 5h window (Claude only). Backward-compatible: absent in older
    // accounts.json → defaults below.
    var autoStartFiveHour: Bool
    var keepAliveConversationID: UUID?
    var lastAutoStartedAt: Date?
    // Billing cycle (all providers). Backward-compatible: absent in older
    // accounts.json → nil. 1…31; clamped to month length at compute time.
    var billingRenewalDay: Int?
    // Paused accounts are fully dormant: excluded from refresh, alerts,
    // warm-up, and the popover, while the signed-in web profile stays on
    // disk. Backward-compatible: absent in older accounts.json → false.
    var isPaused: Bool
    // Subscription plan. Backward-compatible: absent or
    // unknown values in accounts.json → nil.
    var plan: PlanTier?
    var planSource: PlanSource?
    // The newest `WarmUpOutcome.capacity` warm-up outcomes, oldest first.
    // Status codes and kinds only — see `WarmUpOutcome`.
    // Backward-compatible: absent in older accounts.json → []; an entry a
    // newer build wrote that this one cannot read is dropped, never the
    // account.
    var warmUpOutcomes: [WarmUpOutcome]

    init(
        id: UUID,
        provider: Provider,
        label: String,
        webProfileID: UUID,
        displayOrder: Int,
        createdAt: Date,
        autoStartFiveHour: Bool = false,
        keepAliveConversationID: UUID? = nil,
        lastAutoStartedAt: Date? = nil,
        billingRenewalDay: Int? = nil,
        isPaused: Bool = false,
        plan: PlanTier? = nil,
        planSource: PlanSource? = nil,
        warmUpOutcomes: [WarmUpOutcome] = []
    ) {
        self.id = id
        self.provider = provider
        self.label = label
        self.webProfileID = webProfileID
        self.displayOrder = displayOrder
        self.createdAt = createdAt
        self.autoStartFiveHour = autoStartFiveHour
        self.keepAliveConversationID = keepAliveConversationID
        self.lastAutoStartedAt = lastAutoStartedAt
        self.billingRenewalDay = billingRenewalDay
        self.isPaused = isPaused
        self.plan = plan
        self.planSource = planSource
        self.warmUpOutcomes = warmUpOutcomes
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        provider = try container.decode(Provider.self, forKey: .provider)
        label = try container.decode(String.self, forKey: .label)
        webProfileID = try container.decode(UUID.self, forKey: .webProfileID)
        displayOrder = try container.decode(Int.self, forKey: .displayOrder)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        autoStartFiveHour = try container.decodeIfPresent(
            Bool.self, forKey: .autoStartFiveHour
        ) ?? false
        keepAliveConversationID = try container.decodeIfPresent(
            UUID.self, forKey: .keepAliveConversationID
        )
        lastAutoStartedAt = try container.decodeIfPresent(
            Date.self, forKey: .lastAutoStartedAt
        )
        billingRenewalDay = try container.decodeIfPresent(
            Int.self, forKey: .billingRenewalDay
        )
        isPaused = try container.decodeIfPresent(
            Bool.self, forKey: .isPaused
        ) ?? false
        // Lenient: a value written by a newer build must not cost the account.
        plan = (try? container.decodeIfPresent(PlanTier.self, forKey: .plan)) ?? nil
        planSource = plan == nil
            ? nil
            : (try? container.decodeIfPresent(PlanSource.self, forKey: .planSource)) ?? nil
        // Lenient per entry: an outcome this build cannot read is dropped.
        let storedOutcomes = try? container.decodeIfPresent(
            [LenientWarmUpOutcome].self,
            forKey: .warmUpOutcomes
        )
        let readable = (storedOutcomes ?? []).compactMap(\.outcome)
        warmUpOutcomes = Array(readable.suffix(WarmUpOutcome.capacity))
    }
}

/// One `warmUpOutcomes` entry that decodes to nil instead of throwing.
private struct LenientWarmUpOutcome: Decodable {
    let outcome: WarmUpOutcome?

    init(from decoder: any Decoder) throws {
        outcome = try? WarmUpOutcome(from: decoder)
    }
}
