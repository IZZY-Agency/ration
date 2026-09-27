import AppKit
import SwiftUI

/// A pay-as-you-go API platform whose org spend Ration reads with an Admin key.
/// Never a `Provider`: API orgs have no web session.
enum APIVendor: String, Codable, CaseIterable, Sendable {
    case anthropic
    case openAI = "openai"

    var host: String {
        switch self {
        case .anthropic: "api.anthropic.com"
        case .openAI: "api.openai.com"
        }
    }

    /// Brand names — never translated.
    var displayName: String {
        switch self {
        case .anthropic: "Anthropic API"
        case .openAI: "OpenAI API"
        }
    }

    /// Where the user creates an Admin key, named in the regular-key refusal.
    var consoleName: String {
        switch self {
        case .anthropic: "Claude Console"
        case .openAI: "OpenAI Platform"
        }
    }

    var markLetter: String {
        switch self {
        case .anthropic: "A"
        case .openAI: "O"
        }
    }

    /// Vendor accents reuse the subscription brand accents.
    var accent: Color {
        switch self {
        case .anthropic: Theme.gold
        case .openAI: Theme.chatGPTGreen
        }
    }

    var accentNS: NSColor { NSColor(accent) }

    /// Trims the whitespace and newlines a Console copy often carries.
    static func normalizedKey(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func classify(_ raw: String) -> APIKeyKind {
        let key = normalizedKey(raw)
        guard !key.isEmpty,
              key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
        else { return .invalid }
        if key.hasPrefix("sk-ant-admin") { return .admin(.anthropic) }
        if key.hasPrefix("sk-ant-") { return .regular(.anthropic) }
        if key.hasPrefix("sk-admin-") { return .admin(.openAI) }
        if key.hasPrefix("sk-") { return .regular(.openAI) }
        return .invalid
    }
}

enum APIKeyKind: Equatable, Sendable {
    case admin(APIVendor)
    case regular(APIVendor)
    case invalid
}
