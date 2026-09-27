import Foundation

struct OpenAISpendClient: APISpendClient {
    let http: APISpendHTTP
    let now: @Sendable () -> Date
    var vendor: APIVendor { .openAI }

    private func headers(_ key: String) -> [String: String] { ["Authorization": "Bearer \(key)"] }

    private func range(_ month: UTCMonth) -> [URLQueryItem] {
        var items = [
            URLQueryItem(name: "start_time", value: String(Int(month.start.timeIntervalSince1970))),
            URLQueryItem(name: "bucket_width", value: "1d"),
            URLQueryItem(name: "limit", value: "31"),
        ]
        if let end = APISpendEndpoints.endParameter(for: month, now: now()) {
            items.append(URLQueryItem(name: "end_time", value: String(Int(end.timeIntervalSince1970))))
        }
        return items
    }

    func costReport(month: UTCMonth, key: String, refreshStartedAt: Date) async throws -> APICostReport {
        let query = range(month) + [URLQueryItem(name: "group_by", value: "line_item")]
        let pages = try await APISpendEndpoints.allPages { page in
            try await http.get(vendor: .openAI, path: "/v1/organization/costs",
                               query: query + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? []),
                               headers: headers(key)).0
        }
        return try OpenAISpendDecoder.costReport(pages: pages, month: month, fetchedAt: now(), refreshStartedAt: refreshStartedAt)
    }

    func tokenReport(month: UTCMonth, key: String, refreshStartedAt: Date) async throws -> APITokenReport {
        let query = range(month) + [URLQueryItem(name: "group_by", value: "model")]
        let pages = try await APISpendEndpoints.allPages { page in
            try await http.get(vendor: .openAI, path: "/v1/organization/usage/completions",
                               query: query + (page.map { [URLQueryItem(name: "page", value: $0)] } ?? []),
                               headers: headers(key)).0
        }
        return try OpenAISpendDecoder.tokenReport(pages: pages, month: month, fetchedAt: now(), refreshStartedAt: refreshStartedAt)
    }

    /// OpenAI has no documented "who am I" for Admin keys; real responses
    /// carry the organization id in the `openai-organization` response header.
    func identity(key: String) async throws -> OrgIdentity? {
        let month = UTCMonth(containing: now())
        let (_, response) = try await http.get(
            vendor: .openAI, path: "/v1/organization/costs",
            query: range(month).filter { $0.name != "limit" } + [URLQueryItem(name: "limit", value: "1")],
            headers: headers(key)
        )
        return response.value(forHTTPHeaderField: APISpendEndpoints.openAIOrganizationHeader)
            .map { OrgIdentity(id: $0, name: nil) }
    }
}
