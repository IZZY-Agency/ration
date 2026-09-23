import Foundation
import WebKit

@MainActor
enum LiveProviderAdapters {
    /// The production Claude stack shares ONE resolver between the usage
    /// adapter and the auto-start message sender: the adapter records the org
    /// each successful usage fetch actually used, and the sender binds the
    /// irreversible send to exactly that org (see
    /// `ClaudeMessageSender.prepare(boundToOrganizationID:in:)`).
    static func live() -> (
        adapters: [any ProviderAdapter],
        claudeMessageSender: ClaudeMessageSender
    ) {
        let client = WebUsageClient()
        let resolver = ClaudeOrganizationResolver(client: client)
        return (
            [
                ClaudeProviderAdapter(client: client, organizationResolver: resolver),
                ChatGPTProviderAdapter(),
                CursorProviderAdapter()
            ],
            ClaudeMessageSender(client: client, organizationResolver: resolver)
        )
    }

    static var all: [any ProviderAdapter] { live().adapters }
}

@MainActor
struct ClaudeProviderAdapter: ProviderAdapter {
    typealias PrepareWebView = @MainActor (WKWebView) async throws -> Void

    let provider = Provider.claude
    let signInURL = URL(string: "https://claude.ai/settings/usage")!

    private let client: WebUsageClient
    private let now: @MainActor () -> Date
    private let prepareWebView: PrepareWebView
    private let organizationResolver: ClaudeOrganizationResolver

    init(
        client: WebUsageClient = WebUsageClient(),
        now: @escaping @MainActor () -> Date = { .now },
        prepareWebView: @escaping PrepareWebView = ClaudeWebViewPreparation.prepare,
        organizationResolver: ClaudeOrganizationResolver? = nil
    ) {
        self.client = client
        self.now = now
        self.prepareWebView = prepareWebView
        self.organizationResolver = organizationResolver
            ?? ClaudeOrganizationResolver(client: client)
    }

    func verifySession(in webView: WKWebView) async throws {
        try await prepareWebView(webView)
        // Full round trip — resolve the org AND read usage — so "verified"
        // means the session can actually deliver data, not merely that an
        // organization id was findable. Shares the 404 re-resolve dance with
        // `fetchUsage`: a stale cookie-selected org must not block sign-in
        // when a later source holds a valid one.
        _ = try await usageBody(cacheKey: nil, in: webView)
    }

    func fetchUsage(
        accountID: UUID,
        in webView: WKWebView
    ) async throws -> UsageSnapshot {
        try await prepareWebView(webView)
        let (body, organizationID) = try await usageBody(cacheKey: accountID, in: webView)
        let payload: ClaudeUsagePayload = try await decode(body)
        let fiveHour = try usageWindow(from: payload.fiveHour, kind: .fiveHour)
        let weekly = try usageWindow(from: payload.sevenDay, kind: .weekly)
        guard fiveHour != nil || weekly != nil else {
            throw ProviderError.integrationChanged
        }
        let modelWeekly = Self.modelWeeklyWindow(from: payload.limits)

        // The snapshot CARRIES the org its data came from (in memory only —
        // it is excluded from persistence). Auto-start reads it straight off
        // the triggering snapshot, so no shared mutable binding exists to be
        // overwritten or collided by a concurrent fetch.
        let fetchedAt = now()
        return UsageSnapshot(
            accountID: accountID,
            fetchedAt: fetchedAt,
            fiveHour: fiveHour,
            weekly: weekly,
            modelWeekly: modelWeekly,
            organizationID: organizationID,
            resetCredits: Self.resetCredits(from: payload, fetchedAt: fetchedAt)
        )
    }

    /// Resolve → GET usage → validate, with the 404 re-resolve dance shared by
    /// `fetchUsage` and `verifySession`: a 404 means the resolved org no
    /// longer serves usage (workspace switch, revoked membership), so retry
    /// ONCE with that org EXCLUDED — re-reading the same cookie value and
    /// 404ing again would otherwise spuriously read as a changed integration.
    /// A second 404 against a genuinely different org means the endpoint
    /// itself moved → `integrationChanged`, and nothing stays memoized.
    private func usageBody(
        cacheKey: UUID?,
        in webView: WKWebView
    ) async throws -> (body: String, organizationID: String) {
        var organizationID = try await resolveOrganizationID(
            cacheKey: cacheKey,
            excluding: nil,
            in: webView
        )
        var envelope = try await usageEnvelope(organizationID: organizationID, in: webView)
        if envelope.status == 404 {
            organizationResolver.invalidate(cacheKey: cacheKey)
            let freshOrganizationID: String
            do {
                freshOrganizationID = try await resolveOrganizationID(
                    cacheKey: cacheKey,
                    excluding: organizationID,
                    in: webView
                )
            } catch ClaudeOrganizationResolver.ResolutionError.noAlternativeOrganization {
                // Every source DEFINITIVELY confirmed there is no other org
                // (the common single-organization account): the only org this
                // session has just 404ed on its usage endpoint — the endpoint
                // moved. A transient resolution failure does NOT take this
                // path; it stays `.transport` and retries next poll.
                throw ProviderError.integrationChanged
            }
            envelope = try await usageEnvelope(
                organizationID: freshOrganizationID,
                in: webView
            )
            if envelope.status == 404 {
                // Don't leave the known-failing retry org memoized for the
                // next poll to trip over.
                organizationResolver.invalidate(cacheKey: cacheKey)
                throw ProviderError.integrationChanged
            }
            organizationID = freshOrganizationID
        }
        let body = try ProviderResponseValidator.body(from: envelope, now: now())
        return (body, organizationID)
    }

    /// Resolver call with the adapter's error shape: a signed-out session
    /// discovered during resolution becomes `authenticationRequired` (the
    /// Sign In badge); everything else — including
    /// `.noAlternativeOrganization`, which the 404-retry above classifies —
    /// passes through untouched.
    private func resolveOrganizationID(
        cacheKey: UUID?,
        excluding excludedID: String?,
        in webView: WKWebView
    ) async throws -> String {
        do {
            return try await organizationResolver.organizationID(
                cacheKey: cacheKey,
                excluding: excludedID,
                in: webView
            )
        } catch ClaudeOrganizationResolver.ResolutionError.authenticationRequired {
            throw ProviderError.authenticationRequired
        }
    }

    /// Raw usage envelope (status preserved so the caller can run the 404
    /// re-resolve dance before validation).
    private func usageEnvelope(
        organizationID: String,
        in webView: WKWebView
    ) async throws -> WebResponseEnvelope {
        do {
            return try await client.fetch(
                // cedar_ember=1 is the flag claude.ai's own settings page sends
                // to include usage-limit resets; without it the key is null.
                path: "/api/organizations/\(organizationID)/usage?cedar_ember=1",
                expectedOrigin: Provider.claude.webOrigin,
                in: webView
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as ProviderError {
            throw error
        } catch let error as WebUsageClientError where error == .timedOut {
            // Pass the timeout through untouched — AccountSessionManager
            // recycles the web view on it; the refresh coordinator's generic
            // catch maps it to .transport afterwards.
            throw error
        } catch {
            throw ProviderError.transport
        }
    }

    /// `nonisolated async` so the JSON decode runs OFF the main actor (on
    /// the generic executor, per SE-0338), keeping a near-1 MB-capped payload
    /// from blocking the UI on the 5-minute poll. Still structured — inherits
    /// the caller's cancellation. The decoded `Value` is `Sendable`, so handing
    /// it back to the `@MainActor` adapter is race-free.
    private nonisolated func decode<Value: Decodable & Sendable>(
        _ body: String
    ) async throws -> Value {
        do {
            return try JSONDecoder().decode(Value.self, from: Data(body.utf8))
        } catch {
            throw ProviderError.integrationChanged
        }
    }

    private func usageWindow(
        from payload: ClaudeUsageWindowPayload?,
        kind: UsageWindowKind
    ) throws -> UsageWindow? {
        guard let payload else { return nil }
        guard let utilization = payload.utilization else {
            return nil
        }
        guard (0...100).contains(utilization) else {
            throw ProviderError.integrationChanged
        }
        let resetsAt: Date?
        if let resetValue = payload.resetsAt {
            guard let parsedReset = Self.parseISO8601(resetValue) else {
                throw ProviderError.integrationChanged
            }
            resetsAt = parsedReset
        } else {
            resetsAt = nil
        }

        return UsageWindow(
            kind: kind,
            remainingFraction: 1 - (utilization / 100),
            resetsAt: resetsAt
        )
    }

    /// The Max-only gate: a Fable window is present only when `limits[]`
    /// contains a `weekly_scoped` entry with a non-empty scoped model
    /// display name AND a valid `percent`. `is_active` is decoded but
    /// intentionally NOT consulted here — a live Fable window can be
    /// `is_active:false` and still needs to render.
    ///
    /// Selects the first entry satisfying kind + label + valid percent
    /// TOGETHER (not first-kind-match-then-validate): an earlier entry that
    /// matches kind+label but carries a missing/out-of-range percent must
    /// not mask a later entry that is fully valid.
    static func modelWeeklyWindow(from limits: [ClaudeLimitPayload]?) -> UsageWindow? {
        guard let entry = limits?.first(where: { e in
            e.kind == "weekly_scoped"
                && (e.scope?.model?.displayName?.isEmpty == false)
                && (e.percent.map { (0...100).contains($0) } ?? false)
        }) else { return nil }                          // no fully-valid scoped-model limit = non-Max (or malformed) → nil
        let percent = entry.percent!   // guaranteed by the predicate above
        let resetsAt = entry.resetsAt.flatMap(Self.parseISO8601)   // note: is_active is intentionally NOT consulted
        return UsageWindow(
            kind: .modelWeekly,
            remainingFraction: 1 - percent / 100,
            resetsAt: resetsAt,
            label: entry.scope?.model?.displayName
        )
    }

    /// `nil` = not read this fetch (the store carries the previous list).
    /// A grant missing its id/count/expiry, or with an unparseable expiry, is
    /// skipped and marks the list incomplete.
    static func resetCredits(from payload: ClaudeUsagePayload, fetchedAt: Date) -> ResetCredits? {
        guard let grants = payload.cedarEmber?.grants else { return nil }
        var complete = true
        var items: [ResetCredit] = []
        for grant in grants {
            guard let grant, let expiresAt = parseISO8601(grant.endsAt), grant.resetsLeft >= 0 else {
                complete = false
                continue
            }
            guard grant.resetsLeft > 0 else { continue }
            items.append(ResetCredit(
                id: grant.id,
                title: grant.label,
                count: grant.resetsLeft,
                expiresAt: expiresAt,
                usableNow: grant.usableNow
            ))
        }
        return ResetCredits(fetchedAt: fetchedAt, items: items, complete: complete)
    }

    private static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let wholeSeconds = ISO8601DateFormatter()
        wholeSeconds.formatOptions = [.withInternetDateTime]
        return wholeSeconds.date(from: value)
    }
}

/// Decodes to nil instead of throwing when a single element is malformed, so one
/// bad/evolving `limits[]` entry can't sink the whole /usage decode (which carries
/// the healthy 5h/weekly windows).
private struct FailableLimit: Decodable {
    let value: ClaudeLimitPayload?
    init(from decoder: any Decoder) throws { value = try? ClaudeLimitPayload(from: decoder) }
}

struct ClaudeCedarEmberPayload: Decodable, Sendable {
    /// nil = no `grants` array at all → the list was not read.
    let grants: [ClaudeGrantPayload?]?

    enum CodingKeys: String, CodingKey { case grants }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let wrapped = try? c.decodeIfPresent([FailableGrant].self, forKey: .grants) {
            grants = wrapped.map(\.value)
        } else {
            grants = nil
        }
    }
}

private struct FailableGrant: Decodable {
    let value: ClaudeGrantPayload?
    init(from decoder: any Decoder) throws { value = try? ClaudeGrantPayload(from: decoder) }
}

struct ClaudeGrantPayload: Decodable, Sendable {
    let id: String
    let label: String?
    let resetsLeft: Int
    let endsAt: String
    let usableNow: Bool?

    enum CodingKeys: String, CodingKey {
        case id, label
        case resetsLeft = "resets_left"
        case endsAt = "ends_at"
        case usableNow = "usable_now"
    }
}

struct ClaudeUsagePayload: Decodable, Sendable {
    let fiveHour: ClaudeUsageWindowPayload?
    let sevenDay: ClaudeUsageWindowPayload?
    let limits: [ClaudeLimitPayload]?
    let cedarEmber: ClaudeCedarEmberPayload?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
        case cedarEmber = "cedar_ember"
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fiveHour = try c.decodeIfPresent(ClaudeUsageWindowPayload.self, forKey: .fiveHour)
        sevenDay = try c.decodeIfPresent(ClaudeUsageWindowPayload.self, forKey: .sevenDay)
        // Lenient: a wrong-shaped `limits` value (or bad elements) must NOT fail the
        // whole /usage decode — only the model window would be missing, not 5h/weekly.
        if let wrapped = try? c.decodeIfPresent([FailableLimit].self, forKey: .limits) {
            // `try?` on a `T?`-returning expression flattens to `T?` (SE-0230), so
            // `if let` here already unwraps to the non-optional `[FailableLimit]`.
            limits = wrapped.compactMap { $0.value }
        } else {
            limits = nil
        }
        // Lenient: resets are a side channel — a wrong shape means "not read",
        // never a failed usage decode.
        cedarEmber = (try? c.decodeIfPresent(ClaudeCedarEmberPayload.self, forKey: .cedarEmber)) ?? nil
    }
}

struct ClaudeUsageWindowPayload: Decodable, Sendable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

struct ClaudeLimitPayload: Decodable, Sendable {
    let kind: String?
    let percent: Double?
    let resetsAt: String?
    let scope: Scope?
    let isActive: Bool?

    struct Scope: Decodable, Sendable {
        let model: Model?
        let surface: String?
        struct Model: Decodable, Sendable {
            let id: String?
            let displayName: String?
            enum CodingKeys: String, CodingKey { case id; case displayName = "display_name" }
        }
    }
    enum CodingKeys: String, CodingKey {
        case kind, percent, scope
        case resetsAt = "resets_at"
        case isActive = "is_active"
    }
    // Memberwise init for tests:
    init(kind: String?, percent: Double?, resetsAt: String?, scope: Scope?, isActive: Bool?) {
        self.kind = kind; self.percent = percent; self.resetsAt = resetsAt; self.scope = scope; self.isActive = isActive
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        percent = try c.decodeIfPresent(Double.self, forKey: .percent)
        resetsAt = try c.decodeIfPresent(String.self, forKey: .resetsAt)
        scope = try c.decodeIfPresent(Scope.self, forKey: .scope)
        isActive = try c.decodeIfPresent(Bool.self, forKey: .isActive)
    }
}

enum ClaudeUsagePage {
    private static let exactHost = "claude.ai"

    /// Origin-based since the 2026-08 frontend migration: `/settings/usage`
    /// client-redirects to `/new#settings/usage`, so pinning an exact path
    /// broke every fetch while the API stayed healthy. Any settled claude.ai
    /// page is a valid cookie/session host — the bridge scripts enforce the
    /// origin themselves at evaluation time, and a signed-out page simply
    /// yields 401 → Sign In from the usage fetch.
    static func isReady(url: URL?, isLoading: Bool) -> Bool {
        !isLoading && isClaudeOrigin(url)
    }

    static func isClaudeOrigin(_ url: URL?) -> Bool {
        guard let url else { return false }
        return url.scheme?.lowercased() == "https"
            && url.host()?.lowercased() == exactHost
            && (url.port == nil || url.port == 443)
    }
}

@MainActor
private enum ClaudeWebViewPreparation {
    private static let usageURL = URL(string: "https://claude.ai/settings/usage")!

    static func prepare(_ webView: WKWebView) async throws {
        if ClaudeUsagePage.isReady(url: webView.url, isLoading: webView.isLoading) {
            return
        }

        if !ClaudeUsagePage.isClaudeOrigin(webView.url) {
            webView.load(URLRequest(url: usageURL))
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(30))
        while clock.now < deadline {
            try Task.checkCancellation()
            if ClaudeUsagePage.isReady(
                url: webView.url,
                isLoading: webView.isLoading
            ) {
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        throw ProviderError.transport
    }
}
