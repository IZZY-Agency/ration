import Foundation
import WebKit

@MainActor
protocol ProviderAdapter {
    var provider: Provider { get }
    var signInURL: URL { get }

    func verifySession(in webView: WKWebView) async throws
    func fetchUsage(
        accountID: UUID,
        in webView: WKWebView
    ) async throws -> UsageSnapshot
    /// A plan reading that is NOT part of the usage fetch (Claude reads it
    /// from a separate request). nil = nothing new. Default: none.
    func refreshPlanDetection(
        for snapshot: UsageSnapshot,
        in webView: WKWebView
    ) async throws -> PlanDetection?
}

extension ProviderAdapter {
    func refreshPlanDetection(
        for snapshot: UsageSnapshot,
        in webView: WKWebView
    ) async throws -> PlanDetection? { nil }
}

enum ProviderResponseValidator {
    static func body(
        from envelope: WebResponseEnvelope,
        now: Date
    ) throws -> String {
        switch envelope.status {
        case 200..<300:
            return envelope.body
        case 401, 403:
            throw ProviderError.authenticationRequired
        case 429:
            throw ProviderError.rateLimited(
                retryAt: retryAt(from: envelope.retryAfter, now: now)
            )
        default:
            throw ProviderError.server(statusCode: envelope.status)
        }
    }

    /// `Retry-After` is either a non-negative number of seconds or an
    /// HTTP-date (RFC 9110). Parse both; a numeric value wins, otherwise fall
    /// back to the absolute date form.
    static func retryAt(from retryAfter: String?, now: Date) -> Date? {
        guard let retryAfter else { return nil }
        let trimmed = retryAfter.trimmingCharacters(in: .whitespaces)
        if let seconds = TimeInterval(trimmed), seconds >= 0 {
            return now.addingTimeInterval(seconds)
        }
        return httpDateFormatter.date(from: trimmed)
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()
}

@MainActor
struct ProviderAdapterRegistry {
    private let adapters: [Provider: any ProviderAdapter]

    init(adapters: [any ProviderAdapter]) {
        // Last registration wins on a duplicate provider. Avoids the trap that
        // `Dictionary(uniqueKeysWithValues:)` raises if two adapters ever share
        // a provider.
        self.adapters = adapters.reduce(into: [:]) { result, adapter in
            result[adapter.provider] = adapter
        }
    }

    func adapter(for provider: Provider) throws -> any ProviderAdapter {
        guard let adapter = adapters[provider] else {
            throw ProviderError.integrationChanged
        }
        return adapter
    }
}
