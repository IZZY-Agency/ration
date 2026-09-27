import Foundation

struct OrgIdentity: Equatable, Sendable {
    let id: String
    let name: String?
}

protocol APISpendClient: Sendable {
    var vendor: APIVendor { get }
    func costReport(month: UTCMonth, key: String, refreshStartedAt: Date) async throws -> APICostReport
    func tokenReport(month: UTCMonth, key: String, refreshStartedAt: Date) async throws -> APITokenReport
    /// nil when the vendor offers no org identity for this key.
    func identity(key: String) async throws -> OrgIdentity?
}

enum APISpendEndpoints {
    static let maxPages = 10
    /// An end of tomorrow (UTC) includes today's partial bucket;
    /// capped at the month end.
    static func endParameter(for month: UTCMonth, now: Date) -> Date? {
        min(UTCDay.nextStart(after: now), month.nextStart)
    }
    /// OpenAI returns the org id in this response header.
    static let openAIOrganizationHeader = "openai-organization"

    static func rfc3339(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }

    /// Follows `next_page` until done; `pageCap` past `maxPages`.
    static func allPages(
        fetch: (_ page: String?) async throws -> Data
    ) async throws -> [Data] {
        var pages: [Data] = []
        var next: String?
        for index in 0..<maxPages {
            // An org paused or removed mid-report: no further request with its key.
            if index > 0, let wanted = APISpendFetchScope.isStillWanted, !(await wanted()) { throw CancellationError() }
            let data = try await fetch(next)
            pages.append(data)
            let info = try APIPageInfo.decode(data)
            guard info.hasMore else { return pages }
            // More pages but no token: a truncated report must never pass as complete.
            guard let token = info.nextPage, !token.isEmpty else { throw APISpendError.integrationChanged(.decode) }
            next = token
        }
        throw APISpendError.integrationChanged(.pageCap)
    }
}

/// The running fetch's "still wanted" check (set by `APISpendModel.fetchOnce`):
/// paging stops once its org is paused, removed or re-keyed.
enum APISpendFetchScope {
    @TaskLocal static var isStillWanted: (@Sendable () async -> Bool)?
}
