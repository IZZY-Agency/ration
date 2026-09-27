import Foundation
import os

/// The only network path for API spend. Ephemeral session,
/// no cache / cookies / credential storage, fixed hosts, redirects refused.
final class APISpendHTTP: Sendable {
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(protocolClasses: [AnyClass]? = nil, now: @escaping @Sendable () -> Date = { .now }) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 30
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration)
        self.now = now
    }

    func get(
        vendor: APIVendor,
        path: String,
        query: [URLQueryItem],
        headers: [String: String]
    ) async throws -> (Data, HTTPURLResponse) {
        var components = URLComponents()
        components.scheme = "https"
        components.host = vendor.host
        components.path = path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, url.scheme == "https", url.host() == vendor.host else {
            throw APISpendError.integrationChanged(.host)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }

        let recorder = RedirectRefuser()
        let data: Data?
        let response: URLResponse?
        do {
            (data, response) = try await load(request, delegate: recorder)
        } catch let error as URLError {
            if recorder.refused { throw APISpendError.redirectRefused }
            throw Self.map(error)
        } catch {
            if recorder.refused { throw APISpendError.redirectRefused }
            throw APISpendError.transport
        }
        if recorder.refused { throw APISpendError.redirectRefused }
        guard let data, let http = response as? HTTPURLResponse else { throw APISpendError.transport }
        if let failure = Self.map(status: http.statusCode, headers: http.allHeaderFields, now: now()) { throw failure }
        // A captive portal or proxy answers 200 with HTML: "couldn't reach", not "integration changed".
        let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        guard type.contains("json") else { throw APISpendError.transport }
        // …and some label that HTML as JSON: markup is never a report.
        if data.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) == UInt8(ascii: "<") { throw APISpendError.transport }
        return (data, http)
    }

    /// Completion-handler loading, NOT `URLSession.data(for:delegate:)`: when a
    /// refused redirect ends the load with no data, no response and no error,
    /// the async wrapper traps (crashes the app) — here that case is handed back
    /// as nils and becomes `redirectRefused` / `transport`.
    private func load(_ request: URLRequest, delegate: RedirectRefuser) async throws -> (Data?, URLResponse?) {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.dataTask(with: request) { data, response, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: (data, response)) }
            }
            task.delegate = delegate
            task.resume()
        }
    }

    static func map(status: Int, headers: [AnyHashable: Any], now: Date) -> APISpendError? {
        switch status {
        case 200..<300: return nil
        case 300..<400: return .redirectRefused
        case 401: return .keyRejected
        case 403: return .noAdminAccess
        case 429: return .rateLimited(retryAt: retryAfter(headers, now: now))
        case 500..<600: return .server(status: status)
        default: return .integrationChanged(.unexpectedStatus)
        }
    }

    static func map(_ error: URLError) -> APISpendError {
        switch error.code {
        case .timedOut: .timeout
        case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: .offline
        default: .transport
        }
    }

    private static func retryAfter(_ headers: [AnyHashable: Any], now: Date) -> Date? {
        let raw = headers.first { ($0.key as? String)?.caseInsensitiveCompare("Retry-After") == .orderedSame }?.value as? String
        guard let raw = raw?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let seconds = TimeInterval(raw) { return now.addingTimeInterval(seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: raw)
    }
}

/// Per-task delegate: refuses every redirect so the key header can never
/// travel to another host, and remembers that it did.
private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
    private let state = OSAllocatedUnfairLock(initialState: false)
    var refused: Bool { state.withLock { $0 } }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        state.withLock { $0 = true }
        return nil
    }
}
