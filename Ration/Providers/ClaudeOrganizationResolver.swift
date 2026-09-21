import Foundation
import WebKit

/// Resolves the claude.ai organization id for an account WITHOUT depending on
/// the frontend's page structure.
///
/// Until 2026-08, the adapter and the message sender both discovered the org by
/// scraping the usage page's own `/api/organizations/{uuid}/usage` request out
/// of `performance` resource entries. Claude.ai's 2026-08 frontend migration
/// (usage moved to `/new#settings/usage`, which never fires that request)
/// silently broke both. This resolver anchors on things the frontend can't
/// take away without breaking itself:
///
/// 1. the **`lastActiveOrg` cookie** — claude.ai's OWN active-org selector,
///    consulted on EVERY resolution so a workspace switch is picked up at the
///    next poll. Cookie results are NEVER memoized: a memo could otherwise
///    outlive the cookie and keep answering for a workspace the user left.
/// 2. per-key in-memory memo of the expensive fallback steps below, used only
///    when the cookie is absent,
/// 3. `GET /api/organizations` — a real API, not a page artifact — selected
///    from only when the FULL list is decodable and unambiguous,
/// 4. last resort: org-scoped `performance` resource entries, accepted only
///    when UNANIMOUS (every entry names the same org) — conflicting page
///    evidence refuses rather than guesses.
///
/// Error discipline mirrors the adapters: `CancellationError` and
/// `WebUsageClientError.timedOut` always pass through untouched (the recycle
/// contract from ); a 401/403 on the organizations list surfaces as
/// `ResolutionError.authenticationRequired(status:)`; anything else degrades
/// to the next step, and exhausting all steps throws `ProviderError.transport`.
///
/// A class (not a struct) so the state survives being captured by the adapter
/// and sender value types; `@MainActor` like every other web-bridge component.
@MainActor
final class ClaudeOrganizationResolver {
    /// A signed-out session discovered during resolution. Carries the exact
    /// HTTP status because the two consumers need different shapes: the
    /// adapter maps it to `ProviderError.authenticationRequired` (Sign In
    /// badge), the message sender to `SendError.rejected(status:)` (its
    /// long-standing auth contract).
    enum ResolutionError: Error, Equatable {
        case authenticationRequired(status: Int)
        /// Thrown only for an `excluding:` resolution when every source
        /// DEFINITIVELY answered "there is no other organization" (cookie
        /// read succeeded, list decoded to nothing viable, scrape saw no
        /// candidate). The adapter reads this as "the 404ed org was the only
        /// one → the usage endpoint itself moved" (`integrationChanged`). A
        /// transient failure anywhere keeps the ordinary `.transport` so a
        /// flaky poll can never masquerade as a changed integration.
        case noAlternativeOrganization
    }

    /// Outcome of one fallback source. `ambiguous` is list-only: the list
    /// PROVED several viable workspaces, and guessing (or consulting stale
    /// page entries) could publish another workspace's usage — resolution
    /// refuses instead.
    private enum FallbackStep: Equatable {
        case found(String)
        case none
        case ambiguous
        case unavailable
    }

    private let client: WebUsageClient
    /// Memoizes ONLY the fallback (list/scrape) result — never a cookie value.
    private var memo: [UUID: String] = [:]
    /// Ordering guard for `memo`: bumped by every `invalidate` AND at the
    /// start of every keyed resolution, and a fallback result is written only
    /// if the epoch is unchanged when it completes. An older resolution that
    /// suspended across an invalidation or a newer resolution can therefore
    /// never overwrite or resurrect newer state.
    private var epochs: [UUID: Int] = [:]
    init(client: WebUsageClient) {
        self.client = client
    }

    /// Lowercased organization uuid for this account.
    ///
    /// - `cacheKey`: the account id; pass nil for one-shot resolutions that
    ///   must not memoize (sign-in verification, unbound auto-start prepare).
    /// - `excluding`: an org id that just proved invalid (the usage endpoint
    ///   404ed on it). Sources never RETURN it — but exclusion only vetoes a
    ///   would-be selection, it never reshapes ambiguity into certainty (see
    ///   `organizationFromList`).
    func organizationID(
        cacheKey: UUID?,
        excluding excludedID: String? = nil,
        in webView: WKWebView
    ) async throws -> String {
        let epoch = advanceEpoch(cacheKey)

        // The cookie wins on EVERY resolution — it is claude.ai's own record
        // of the currently active workspace — and is never memoized.
        let cookie = try await activeOrganizationFromCookie(in: webView)
        if let fromCookie = cookie.organizationID, fromCookie != excludedID {
            return fromCookie
        }

        if let cacheKey, let memoized = memo[cacheKey], memoized != excludedID {
            return memoized
        }

        let resolved = try await resolveFromFallbacks(
            excluding: excludedID,
            cookieWasDefinitive: cookie.definitive,
            in: webView
        )
        if let cacheKey, epochs[cacheKey, default: 0] == epoch {
            memo[cacheKey] = resolved
        }
        return resolved
    }

    /// Drops the memoized fallback state for this key. Called by the adapter
    /// when the usage endpoint 404s — the org is no longer valid (org
    /// switch, revoked membership) and must not be served from memory.
    func invalidate(cacheKey: UUID?) {
        guard let cacheKey else { return }
        memo.removeValue(forKey: cacheKey)
        epochs[cacheKey, default: 0] += 1
    }

    private func advanceEpoch(_ cacheKey: UUID?) -> Int? {
        guard let cacheKey else { return nil }
        epochs[cacheKey, default: 0] += 1
        return epochs[cacheKey]
    }

    private func resolveFromFallbacks(
        excluding excludedID: String?,
        cookieWasDefinitive: Bool,
        in webView: WKWebView
    ) async throws -> String {
        let list = try await organizationFromList(excluding: excludedID, in: webView)
        switch list {
        case let .found(id):
            return id
        case .ambiguous:
            // The list PROVED several viable workspaces and nothing can pick
            // among them safely — refuse rather than guess (stale page
            // entries included: they don't prove which workspace is ACTIVE).
            throw ProviderError.transport
        case .none:
            // The list DECODED and the only viable org is the excluded one.
            // That knowledge supersedes page scraping — a stale or
            // never-viable entry must not bypass the list's judgment. With a
            // definitive cookie read this is a PROVEN "no alternative".
            if excludedID != nil, cookieWasDefinitive {
                throw ResolutionError.noAlternativeOrganization
            }
            throw ProviderError.transport
        case .unavailable:
            break
        }

        // Page evidence is the last resort, consulted only when the list is
        // unknowable — and only when it is UNANIMOUS.
        let entries = try await organizationFromResourceEntries(
            excluding: excludedID,
            in: webView
        )
        if case let .found(id) = entries { return id }
        throw ProviderError.transport
    }

    private func activeOrganizationFromCookie(
        in webView: WKWebView
    ) async throws -> (organizationID: String?, definitive: Bool) {
        let value: String?
        do {
            value = try await client.lastActiveOrganizationCookie(
                expectedOrigin: Provider.claude.webOrigin,
                in: webView
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WebUsageClientError where error == .timedOut {
            throw error
        } catch {
            // The read itself failed — nothing definitive can be said about
            // the cookie's absence.
            return (nil, false)
        }
        guard let value, let uuid = UUID(uuidString: value) else {
            return (nil, true)
        }
        return (uuid.uuidString.lowercased(), true)
    }

    private func organizationFromList(
        excluding excludedID: String?,
        in webView: WKWebView
    ) async throws -> FallbackStep {
        let envelope: WebResponseEnvelope
        do {
            envelope = try await client.fetch(
                path: "/api/organizations",
                expectedOrigin: Provider.claude.webOrigin,
                in: webView
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WebUsageClientError where error == .timedOut {
            throw error
        } catch {
            return .unavailable
        }

        // A signed-out session must surface as such — the badge flips to
        // Sign In instead of an endless, useless stale/transport retry.
        if envelope.status == 401 || envelope.status == 403 {
            throw ResolutionError.authenticationRequired(status: envelope.status)
        }
        guard (200..<300).contains(envelope.status) else { return .unavailable }

        guard
            let data = envelope.body.data(using: .utf8),
            let wrapped = try? JSONDecoder().decode([FailableOrganization].self, from: data)
        else {
            return .unavailable
        }
        let decoded = wrapped.compactMap { $0.value?.normalized }
        // An element that failed to decode (no valid uuid, or no capabilities
        // array to judge it by) is a membership we know NOTHING about — it
        // could be the active workspace. Selecting among the survivors would
        // risk publishing another workspace's usage as this account's.
        guard decoded.count == wrapped.count else { return .unavailable }

        // An EMPTY organizations array for an authenticated session is a
        // state this integration has never observed — treat it as unknowable
        // rather than as proof that no org exists.
        if decoded.isEmpty { return .unavailable }

        // Selection runs on the FULL list; the exclusion only VETOES the
        // result afterwards. Filtering first would let a failed org's removal
        // manufacture certainty (e.g. [A(chat), B(billing)] with A excluded
        // must NOT select B — B was never chat-capable).
        let selected: OrganizationPayload.Normalized?
        if decoded.count == 1 {
            selected = decoded[0]
        } else {
            let chatCapable = decoded.filter { $0.capabilities.contains("chat") }
            selected = chatCapable.count == 1 ? chatCapable[0] : nil
        }
        guard let selected else {
            // Multiple memberships and no single chat-capable one: the list
            // PROVED ambiguity — the caller refuses rather than guessing.
            return .ambiguous
        }
        // The viable selection IS the excluded org: the decoded list proves
        // there is no alternative (`.none` — the caller will not scrape past
        // this judgment).
        guard selected.uuid != excludedID else { return .none }
        return .found(selected.uuid)
    }

    private func organizationFromResourceEntries(
        excluding excludedID: String?,
        in webView: WKWebView
    ) async throws -> FallbackStep {
        let paths: [String]
        do {
            paths = try await client.resourcePaths(
                expectedOrigin: Provider.claude.webOrigin,
                in: webView
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WebUsageClientError where error == .timedOut {
            throw error
        } catch {
            return .unavailable
        }
        // Page evidence is accepted only when it is UNANIMOUS across every
        // org the page WITNESSED — the excluded org included. Filtering the
        // excluded org first would let `[stale-A, incidental-B]` collapse to
        // a fake "unanimous B" after A's usage 404 and bind the snapshot to
        // a workspace nothing proved active. Exclusion only VETOES a
        // unanimous result, never reshapes conflicted testimony.
        var distinctOrganizations: [String] = []
        for path in paths {
            let segments = path.split(separator: "/")
            guard
                segments.count >= 3,
                segments[0] == "api",
                segments[1] == "organizations",
                let uuid = UUID(uuidString: String(segments[2]))
            else {
                continue
            }
            let candidate = uuid.uuidString.lowercased()
            if !distinctOrganizations.contains(candidate) {
                distinctOrganizations.append(candidate)
            }
        }
        switch distinctOrganizations.count {
        case 0: return .none
        case 1: return distinctOrganizations[0] == excludedID
            ? .none
            : .found(distinctOrganizations[0])
        default: return .ambiguous
        }
    }
}

/// Lenient element decode (same pattern as `FailableLimit`): one malformed or
/// evolving element must not sink the whole organizations list — but the
/// resolver refuses to SELECT from a list with undecodable members (see
/// `organizationFromList`).
private struct FailableOrganization: Decodable {
    let value: OrganizationPayload?
    init(from decoder: any Decoder) throws {
        value = try? OrganizationPayload(from: decoder)
    }
}

/// LIVE-PINNED 2026-08-13 against `GET https://claude.ai/api/organizations`:
/// an array of objects carrying `uuid` (string), `name`, `capabilities`
/// (string array — the active chat org carries "chat"), `rate_limit_tier`,
/// `billing_type`. Only `uuid` and `capabilities` are consumed, and BOTH are
/// required: an element without a capabilities array cannot be judged by the
/// selection rules, so it must count as undecodable rather than as an org
/// with no capabilities.
private struct OrganizationPayload: Decodable {
    let uuid: String?
    let capabilities: [String]?

    struct Normalized {
        let uuid: String
        let capabilities: [String]
    }

    var normalized: Normalized? {
        guard
            let uuid,
            let parsed = UUID(uuidString: uuid),
            let capabilities
        else { return nil }
        return Normalized(
            uuid: parsed.uuidString.lowercased(),
            capabilities: capabilities
        )
    }
}
