import Foundation

struct AnthropicSpendClient: APISpendClient {
    let http: APISpendHTTP
    let now: @Sendable () -> Date
    var vendor: APIVendor { .anthropic }

    private func headers(_ key: String) -> [String: String] {
        ["x-api-key": key, "anthropic-version": "2023-06-01"]
    }

    private func range(_ month: UTCMonth) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "starting_at", value: APISpendEndpoints.rfc3339(month.start)),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ]
        if let end = APISpendEndpoints.endParameter(for: month, now: now()) {
            items.append(URLQueryItem(name: "ending_at", value: APISpendEndpoints.rfc3339(end)))
        }
        return items
    }

    func costReport(month: UTCMonth, key: String, refreshStartedAt: Date) async throws -> APICostReport {
        let query = range(month) + [URLQueryItem(name: "group_by[]", value: "description")]
        let pages = try await APISpendEndpoints.allPages { page in
            try await http.get(vendor: .anthropic, path: "/v1/organizations/cost_report",
                               query: query + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? []),
                               headers: headers(key)).0
        }
        return try AnthropicSpendDecoder.costReport(pages: pages, month: month, fetchedAt: now(), refreshStartedAt: refreshStartedAt)
    }

    func tokenReport(month: UTCMonth, key: String, refreshStartedAt: Date) async throws -> APITokenReport {
        let query = range(month) + [URLQueryItem(name: "group_by[]", value: "model"), URLQueryItem(name: "group_by[]", value: "service_tier")]
        let pages = try await APISpendEndpoints.allPages { page in
            try await http.get(vendor: .anthropic, path: "/v1/organizations/usage_report/messages",
                               query: query + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? []),
                               headers: headers(key)).0
        }
        return try AnthropicSpendDecoder.tokenReport(pages: pages, month: month, fetchedAt: now(), refreshStartedAt: refreshStartedAt)
    }

    func identity(key: String) async throws -> OrgIdentity? {
        struct Me: Decodable { let id: String; let name: String? }
        let (data, _) = try await http.get(vendor: .anthropic, path: "/v1/organizations/me", query: [], headers: headers(key))
        do {
            let me = try JSONDecoder().decode(Me.self, from: data)
            return OrgIdentity(id: me.id, name: me.name)
        } catch {
            throw APISpendError.integrationChanged(.decode)
        }
    }
}
