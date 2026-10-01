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
        if let failure = Self.map(status: http.statusCode, headers: http.allHeaderFields, now: now()) {
            if case .integrationChanged = failure {
                // The status and the vendor's own error text, so an answer
                // Ration does not expect can be diagnosed. Never the key or
                // the query: only the path and what the vendor said.
                Self.log.error("api-spend unexpected status=\(http.statusCode, privacy: .public) vendor=\(vendor.rawValue, privacy: .public) path=\(path, privacy: .public) message=\(Self.errorMessage(data), privacy: .public)")
            }
            throw failure
        }
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

    private static let log = Logger(subsystem: "agency.izzy.ration", category: "api-spend")

    /// The vendor's error message (`error.type: error.message`, Anthropic and
    /// OpenAI) for the log: at most 300 characters of letters, digits, spaces
    /// and `_:.,'()-`, with anything key-like (`sk-…`) and any run of 20+
    /// token characters holding a digit (an id or a token) replaced by "…", so no credential or id can reach a
    /// public log even if a vendor echoed one. "" when the body is not that shape.
    static func errorMessage(_ data: Data?) -> String {
        struct Body: Decodable {
            struct Inner: Decodable { let type: String?; let message: String? }
            let error: Inner?
        }
        guard let data, let body = try? JSONDecoder().decode(Body.self, from: data), let error = body.error else { return "" }
        var text = [error.type, error.message].compactMap { $0 }.joined(separator: ": ")
        text = text.replacingOccurrences(of: #"sk-[A-Za-z0-9_\-]*"#, with: "…", options: .regularExpression)
        // Words like "invalid_request_error" stay; ids and tokens carry digits.
        text = text.replacingOccurrences(of: #"(?=[A-Za-z0-9_\-]*[0-9])[A-Za-z0-9_\-]{20,}"#, with: "…", options: .regularExpression)
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 _:.,'()-…")
        return String(text.prefix(300).filter { allowed.contains($0) })
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
