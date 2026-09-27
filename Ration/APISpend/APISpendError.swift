import Foundation

/// Sanitized API-spend failures. Carries NO underlying error, URL,
/// header or body — nothing that could ever hold an Admin key.
enum APISpendError: Error, Equatable, Sendable {
    enum IntegrationReason: String, Sendable {
        case decode, pageCap, currency, amountOutOfRange, host, unexpectedStatus
    }

    case keyRejected                 // 401
    case noAdminAccess               // 403
    case rateLimited(retryAt: Date?) // 429
    case server(status: Int)         // 5xx
    case timeout
    case offline
    case transport
    case redirectRefused
    case integrationChanged(IntegrationReason)
    case keyMissing
    case keychain(status: Int32)
}
