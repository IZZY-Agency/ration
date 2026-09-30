import Foundation

/// The folder the user granted (spec §3): an app-scoped,
/// security-scoped, read-only bookmark from the open panel.
protocol TokenBurnFolderAccess: Sendable {
    func bookmark(for folder: URL) throws -> Data
    /// The folder again, after a relaunch or an update, and whether the
    /// bookmark is stale (it must be replaced). Throws when it no longer
    /// resolves.
    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool)
    func startAccessing(_ url: URL) -> Bool
    func stopAccessing(_ url: URL)
}

struct SecurityScopedFolderAccess: TokenBurnFolderAccess {
    func bookmark(for folder: URL) throws -> Data {
        try folder.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                                includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, isStale: Bool) {
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope, .withoutUI],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        return (url, stale)
    }

    func startAccessing(_ url: URL) -> Bool { url.startAccessingSecurityScopedResource() }
    func stopAccessing(_ url: URL) { url.stopAccessingSecurityScopedResource() }
}

/// `token-burn.json`: whether the feature is on and its grant. No path.
struct TokenBurnSettings: Codable, Equatable, Sendable {
    var enabled = false
    var bookmark: Data?
    var grantedAt: Date?
    /// The period the figures cover; forgotten with everything else.
    var period: TokenBurnPeriod.Choice = .last30Days

    init() {}

    enum CodingKeys: String, CodingKey { case enabled, bookmark, grantedAt, period }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false
        bookmark = try? container.decodeIfPresent(Data.self, forKey: .bookmark)
        grantedAt = try? container.decodeIfPresent(Date.self, forKey: .grantedAt)
        period = (try? container.decodeIfPresent(TokenBurnPeriod.Choice.self, forKey: .period)) ?? .last30Days
    }
}
