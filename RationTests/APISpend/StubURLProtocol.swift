import Foundation

/// URLProtocol stub for API-spend clients. Handlers are keyed by URL path.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply { var status = 200; var headers: [String: String] = ["Content-Type": "application/json"]; var body = Data(); var redirectTo: URL? }
    nonisolated(unsafe) static var replies: [String: [Reply]] = [:]
    nonisolated(unsafe) static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() { lock.withLock { replies = [:]; requests = [] } }
    static func enqueue(_ path: String, _ reply: Reply) { lock.withLock { replies[path, default: []].append(reply) } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let reply: Reply = Self.lock.withLock {
            Self.requests.append(request)
            return Self.replies[path]?.isEmpty == false ? Self.replies[path]!.removeFirst() : Reply(status: 404)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if let target = reply.redirectTo {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
