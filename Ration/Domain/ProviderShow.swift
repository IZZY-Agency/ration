import Foundation

/// What a provider can show or hide (Settings → General → Features → Show per
/// provider). Presentation and alert gating
/// only: reading, alert bookkeeping and dedupe keep running while a switch is
/// off, so turning it back on shows current figures instead of a backlog.
enum ProviderShowItem: String, CaseIterable, Sendable {
    /// Usage credits (Claude), Codex credits (ChatGPT), a prepaid balance
    /// (TypeSafe): card line, account-pane section, Alerts rows, warnings.
    case credits
    /// Usage-limit resets: card line, account-pane list, Alerts row, alerts.
    case resets
    /// Claude plan value from Claude Code logs: card line, popover total,
    /// account-pane section, History mode. Counting itself is the plan-value
    /// switch's (it needs consent to read the logs).
    case tokenBurn

    /// The providers this item exists for, in `Provider.allCases` order.
    var providers: [Provider] {
        switch self {
        case .credits: [.claude, .chatGPT, .typeSafe]
        case .resets: [.claude, .chatGPT]
        case .tokenBurn: [.claude]
        }
    }

    func applies(to provider: Provider) -> Bool { providers.contains(provider) }

    /// The grid's columns: providers switched on in this build that have at
    /// least one item.
    static var columns: [Provider] {
        Provider.allCases.filter { provider in provider.isOffered && allCases.contains { $0.applies(to: provider) } }
    }

    func title(locale: Locale = .current) -> String {
        let resource: LocalizedStringResource = switch self {
        case .credits: .providerShowCredits
        case .resets: .providerShowResets
        case .tokenBurn: .providerShowTokenBurn
        }
        return resource.string(in: locale)
    }

    /// The settings key: "claude.resets".
    static func key(_ item: ProviderShowItem, _ provider: Provider) -> String {
        "\(provider.rawValue).\(item.rawValue)"
    }
}

/// Every provider's show switches as one value, for views and pure gating.
///
/// A provider with no choice of its own falls back to the global switch it
/// replaced (`featureUsageCreditsEnabled`, `featureResetsEnabled`), so a
/// setting chosen before the grid existed carries over without a rewrite;
/// token burn, new with the grid, is on.
struct ProviderShow: Equatable, Sendable {
    var choices: [String: Bool]
    var legacyCredits: Bool
    var legacyResets: Bool

    static let allOn = ProviderShow(choices: [:], legacyCredits: true, legacyResets: true)

    func shows(_ item: ProviderShowItem, for provider: Provider) -> Bool {
        if let choice = choices[ProviderShowItem.key(item, provider)] { return choice }
        switch item {
        case .credits: return legacyCredits
        case .resets: return legacyResets
        case .tokenBurn: return true
        }
    }
}
