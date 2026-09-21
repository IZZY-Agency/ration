import WebKit
import XCTest
@testable import Ration

/// The resolver replaces performance-entry scraping as the primary way to find
/// the account's organization id after claude.ai's 2026-08 frontend migration
/// (usage page moved to `/new#settings/usage`; the page no longer fires the
/// `/api/organizations/{uuid}/usage` request the old discovery scraped).
/// Resolution order: `lastActiveOrg` cookie (every time, never memoized) →
/// per-key memo of the fallbacks → GET `/api/organizations` (full-list
/// unambiguous selection only) → performance-entry scrape (newest `/usage`
/// entry preferred over other org-scoped paths).
@MainActor
final class ClaudeOrganizationResolverTests: XCTestCase {
    private static let org = "20553b43-bbde-4a26-95e3-b385724ddcd4"
    private static let otherOrg = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee"

    /// Evaluator distinguishing the three bridge scripts the resolver can run.
    private static func evaluator(
        cookie: Any? = NSNull(),
        organizationsEnvelope: [String: Any]? = nil,
        resourcePaths: [String] = [],
        callLog: (@MainActor (String) -> Void)? = nil
    ) -> WebUsageClient.Evaluator {
        { script, arguments, _ in
            if script.contains("lastActiveOrg") {
                callLog?("cookie")
                return cookie
            }
            if arguments["path"] as? String == "/api/organizations" {
                callLog?("list")
                return organizationsEnvelope ?? [
                    "status": 200, "retryAfter": NSNull(), "body": "[]"
                ]
            }
            if script.contains("getEntriesByType") {
                callLog?("scrape")
                return resourcePaths
            }
            XCTFail("unexpected script evaluation: \(script.prefix(60))")
            return NSNull()
        }
    }

    private func resolver(_ evaluator: @escaping WebUsageClient.Evaluator) -> ClaudeOrganizationResolver {
        ClaudeOrganizationResolver(client: WebUsageClient(evaluator: evaluator))
    }

    func testCookieWinsWithoutTouchingListOrScrape() async throws {
        var calls: [String] = []
        let resolver = resolver(Self.evaluator(cookie: Self.org) { calls.append($0) })

        let id = try await resolver.organizationID(cacheKey: nil, in: WKWebView())

        XCTAssertEqual(id, Self.org)
        XCTAssertEqual(calls, ["cookie"])
    }

    func testCookieValueMustBeAUUID() async throws {
        let resolver = resolver(Self.evaluator(
            cookie: "not-a-uuid",
            organizationsEnvelope: [
                "status": 200, "retryAfter": NSNull(),
                "body": "[{\"uuid\":\"\(Self.org)\",\"capabilities\":[\"chat\"]}]"
            ]
        ))

        let id = try await resolver.organizationID(cacheKey: nil, in: WKWebView())

        XCTAssertEqual(id, Self.org, "garbage cookie falls through to the list")
    }

    func testSingleOrganizationFromListWhenCookieAbsent() async throws {
        let resolver = resolver(Self.evaluator(
            organizationsEnvelope: [
                "status": 200, "retryAfter": NSNull(),
                "body": "[{\"uuid\":\"\(Self.org)\",\"capabilities\":[\"chat\",\"claude_max\"]}]"
            ]
        ))

        let id = try await resolver.organizationID(cacheKey: nil, in: WKWebView())

        XCTAssertEqual(id, Self.org)
    }

    func testMultipleOrganizationsPreferTheSingleChatCapableOne() async throws {
        let body = """
        [{"uuid":"\(Self.otherOrg)","capabilities":["billing"]},
         {"uuid":"\(Self.org)","capabilities":["chat"]}]
        """
        let resolver = resolver(Self.evaluator(
            organizationsEnvelope: ["status": 200, "retryAfter": NSNull(), "body": body]
        ))

        let id = try await resolver.organizationID(cacheKey: nil, in: WKWebView())

        XCTAssertEqual(id, Self.org)
    }

    /// A list that PROVED several viable workspaces must refuse resolution
    /// entirely — stale page entries cannot prove which one is ACTIVE, so
    /// falling to the scrape would risk publishing another workspace's usage.
    func testProvenlyAmbiguousListRefusesToGuess() async {
        var calls: [String] = []
        let body = """
        [{"uuid":"\(Self.otherOrg)","capabilities":["chat"]},
         {"uuid":"\(Self.org)","capabilities":["chat"]}]
        """
        let resolver = resolver(Self.evaluator(
            organizationsEnvelope: ["status": 200, "retryAfter": NSNull(), "body": body],
            resourcePaths: ["/api/organizations/\(Self.org)/prepaid/bundles"],
            callLog: { calls.append($0) }
        ))

        do {
            _ = try await resolver.organizationID(cacheKey: nil, in: WKWebView())
            XCTFail("expected transport")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .transport)
            XCTAssertFalse(calls.contains("scrape"), "proven ambiguity must never reach the scrape")
        } catch {
            XCTFail("expected ProviderError.transport, got \(error)")
        }
    }

    func testScrapeAcceptsAnyOrgScopedPathNotJustUsage() async throws {
        let resolver = resolver(Self.evaluator(
            organizationsEnvelope: ["status": 200, "retryAfter": NSNull(), "body": "[]"],
            resourcePaths: [
                "/api/account",
                "/api/organizations/\(Self.org)/prepaid/bundles"
            ]
        ))

        let id = try await resolver.organizationID(cacheKey: nil, in: WKWebView())

        XCTAssertEqual(id, Self.org)
    }

    /// An element that fails to decode is a membership we know nothing about —
    /// it could be the active workspace. The list must refuse to select and
    /// fall through to the scrape instead of treating the survivors as the
    /// whole truth (which could publish another workspace's usage).
    func testUndecodableListElementRefusesSelectionAndFallsToScrape() async {
        let body = """
        [{"unexpected":42},
         {"uuid":"\(Self.otherOrg)","capabilities":["chat"]}]
        """
        let resolver = resolver(Self.evaluator(
            organizationsEnvelope: ["status": 200, "retryAfter": NSNull(), "body": body],
            resourcePaths: ["/api/organizations/\(Self.org)/usage"]
        ))

        do {
            let id = try await resolver.organizationID(cacheKey: nil, in: WKWebView())
            XCTAssertEqual(
                id, Self.org,
                "must come from the scrape, not from the decodable survivor"
            )
        } catch {
            XCTFail("expected scrape fallback, got \(error)")
        }
    }

    /// The cookie is claude.ai's own active-workspace selector and must win on
    /// EVERY resolution — a memoized org from an earlier poll must not outlive
    /// a workspace switch just because its usage endpoint still answers 200.
    func testCookieSwitchOverridesMemoizedOrganization() async throws {
        let key = UUID()
        var cookie = Self.org
        let client = WebUsageClient { script, _, _ in
            if script.contains("lastActiveOrg") { return cookie }
            XCTFail("cookie must satisfy every resolution: \(script.prefix(60))")
            return NSNull()
        }
        let resolver = ClaudeOrganizationResolver(client: client)

        let first = try await resolver.organizationID(cacheKey: key, in: WKWebView())
        cookie = Self.otherOrg
        let second = try await resolver.organizationID(cacheKey: key, in: WKWebView())

        XCTAssertEqual(first, Self.org)
        XCTAssertEqual(second, Self.otherOrg)
    }

    /// `excluding:` is the 404-retry contract: the org that just 404ed must be
    /// skipped by EVERY source, so the retry genuinely reaches later sources
    /// (here: excluded cookie → unavailable list → scrape).
    func testExcludedOrgIsSkippedByEverySource() async throws {
        let resolver = resolver(Self.evaluator(
            cookie: Self.otherOrg,
            organizationsEnvelope: ["status": 500, "retryAfter": NSNull(), "body": ""],
            resourcePaths: ["/api/organizations/\(Self.org)/usage"]
        ))

        let id = try await resolver.organizationID(
            cacheKey: nil,
            excluding: Self.otherOrg,
            in: WKWebView()
        )

        XCTAssertEqual(id, Self.org)
    }

    /// Page evidence is accepted only when UNANIMOUS: entries naming two
    /// DIFFERENT organizations prove nothing about which is active, so the
    /// resolver refuses to guess (no heuristic ranking of usage-vs-newer).
    func testConflictingScrapeEntriesRefuseResolution() async {
        let resolver = resolver(Self.evaluator(
            organizationsEnvelope: ["status": 500, "retryAfter": NSNull(), "body": ""],
            resourcePaths: [
                "/api/organizations/\(Self.org)/usage",
                "/api/organizations/\(Self.otherOrg)/prepaid/bundles"
            ]
        ))

        do {
            _ = try await resolver.organizationID(cacheKey: nil, in: WKWebView())
            XCTFail("expected transport")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .transport)
        } catch {
            XCTFail("expected ProviderError.transport, got \(error)")
        }
    }

    func testNothingFoundThrowsTransport() async {
        let resolver = resolver(Self.evaluator())

        do {
            _ = try await resolver.organizationID(cacheKey: nil, in: WKWebView())
            XCTFail("expected transport")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .transport)
        } catch {
            XCTFail("expected ProviderError.transport, got \(error)")
        }
    }

    func testListAuthFailureSurfacesWithExactStatus() async {
        for status in [401, 403] {
            let resolver = resolver(Self.evaluator(
                organizationsEnvelope: ["status": status, "retryAfter": NSNull(), "body": ""]
            ))

            do {
                _ = try await resolver.organizationID(cacheKey: nil, in: WKWebView())
                XCTFail("expected authenticationRequired(\(status))")
            } catch let error as ClaudeOrganizationResolver.ResolutionError {
                XCTAssertEqual(error, .authenticationRequired(status: status))
            } catch {
                XCTFail("expected authenticationRequired(\(status)), got \(error)")
            }
        }
    }

    func testListServerErrorDegradesToScrape() async throws {
        let resolver = resolver(Self.evaluator(
            organizationsEnvelope: ["status": 500, "retryAfter": NSNull(), "body": ""],
            resourcePaths: ["/api/organizations/\(Self.org)/usage"]
        ))

        let id = try await resolver.organizationID(cacheKey: nil, in: WKWebView())

        XCTAssertEqual(id, Self.org)
    }

    /// The memo covers only the expensive fallback steps: the cookie is
    /// re-read every resolution (it is the workspace-switch signal), but a
    /// cookie-less session must not re-fetch the organizations list per poll.
    func testMemoServesFallbackResultWhenCookieAbsent() async throws {
        var calls: [String] = []
        let key = UUID()
        let resolver = resolver(Self.evaluator(
            organizationsEnvelope: [
                "status": 200, "retryAfter": NSNull(),
                "body": "[{\"uuid\":\"\(Self.org)\",\"capabilities\":[\"chat\"]}]"
            ],
            callLog: { calls.append($0) }
        ))

        let first = try await resolver.organizationID(cacheKey: key, in: WKWebView())
        let second = try await resolver.organizationID(cacheKey: key, in: WKWebView())

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            calls, ["cookie", "list", "cookie"],
            "second call re-reads the cookie but serves the fallback from memo"
        )
    }

    func testInvalidateForcesFallbackReResolution() async throws {
        var calls: [String] = []
        let key = UUID()
        let resolver = resolver(Self.evaluator(
            organizationsEnvelope: [
                "status": 200, "retryAfter": NSNull(),
                "body": "[{\"uuid\":\"\(Self.org)\",\"capabilities\":[\"chat\"]}]"
            ],
            callLog: { calls.append($0) }
        ))

        _ = try await resolver.organizationID(cacheKey: key, in: WKWebView())
        resolver.invalidate(cacheKey: key)
        _ = try await resolver.organizationID(cacheKey: key, in: WKWebView())

        XCTAssertEqual(calls, ["cookie", "list", "cookie", "list"])
    }

    func testNilCacheKeyNeverMemoizes() async throws {
        var calls: [String] = []
        let resolver = resolver(Self.evaluator(
            organizationsEnvelope: [
                "status": 200, "retryAfter": NSNull(),
                "body": "[{\"uuid\":\"\(Self.org)\",\"capabilities\":[\"chat\"]}]"
            ],
            callLog: { calls.append($0) }
        ))

        _ = try await resolver.organizationID(cacheKey: nil, in: WKWebView())
        _ = try await resolver.organizationID(cacheKey: nil, in: WKWebView())

        XCTAssertEqual(calls, ["cookie", "list", "cookie", "list"])
    }

    /// The memo must never hold a cookie-derived value: if the cookie later
    /// becomes absent (cleared, expired, transient read failure) the resolver
    /// must consult the LIVE fallbacks, not replay the departed workspace.
    func testCookieValueIsNeverMemoized() async throws {
        let key = UUID()
        var cookie: Any = Self.org
        var listBody = "[{\"uuid\":\"\(Self.otherOrg)\",\"capabilities\":[\"chat\"]}]"
        let client = WebUsageClient { script, arguments, _ in
            if script.contains("lastActiveOrg") { return cookie }
            if arguments["path"] as? String == "/api/organizations" {
                return ["status": 200, "retryAfter": NSNull(), "body": listBody]
            }
            XCTFail("unexpected evaluation: \(script.prefix(60))")
            return NSNull()
        }
        let resolver = ClaudeOrganizationResolver(client: client)

        let first = try await resolver.organizationID(cacheKey: key, in: WKWebView())
        cookie = NSNull()
        let second = try await resolver.organizationID(cacheKey: key, in: WKWebView())

        XCTAssertEqual(first, Self.org)
        XCTAssertEqual(
            second, Self.otherOrg,
            "with the cookie gone, the list must answer — not a memo of the cookie"
        )
    }

    /// Await-spanning ordering: a resolution that was already in flight when
    /// `invalidate` landed must not memoize its (now stale) result.
    func testResolutionInFlightAcrossInvalidateDoesNotMemoize() async throws {
        let key = UUID()
        var listBody = "[{\"uuid\":\"\(Self.org)\",\"capabilities\":[\"chat\"]}]"
        var suspendNextList = true
        var listGate: CheckedContinuation<Void, Never>?
        var listCalls = 0
        let client = WebUsageClient { script, arguments, _ in
            if script.contains("lastActiveOrg") { return NSNull() }
            if arguments["path"] as? String == "/api/organizations" {
                listCalls += 1
                if suspendNextList {
                    suspendNextList = false
                    await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
                        listGate = gate
                    }
                }
                return ["status": 200, "retryAfter": NSNull(), "body": listBody]
            }
            XCTFail("unexpected evaluation: \(script.prefix(60))")
            return NSNull()
        }
        let resolver = ClaudeOrganizationResolver(client: client)

        let inFlight = Task { @MainActor in
            try await resolver.organizationID(cacheKey: key, in: WKWebView())
        }
        while listGate == nil { await Task.yield() }
        resolver.invalidate(cacheKey: key)
        listGate?.resume()
        _ = try await inFlight.value

        // If the stale resolution had memoized, this second call would serve
        // the old org from the memo without a fresh list read.
        listBody = "[{\"uuid\":\"\(Self.otherOrg)\",\"capabilities\":[\"chat\"]}]"
        let second = try await resolver.organizationID(cacheKey: key, in: WKWebView())
        XCTAssertEqual(second, Self.otherOrg)
        XCTAssertEqual(listCalls, 2, "the stale result must not have been memoized")
    }

    /// Exclusion only VETOES a selection — it must never reshape ambiguity
    /// into certainty, and a DECODED list's judgment is final: with
    /// `[A(chat), B(billing)]` and A excluded there is provably no viable
    /// alternative, so resolution reports exactly that (never promoting B,
    /// and never letting a stale page entry bypass the list's judgment).
    func testExclusionOnDecodedListProvesNoAlternative() async {
        var calls: [String] = []
        let body = """
        [{"uuid":"\(Self.org)","capabilities":["chat"]},
         {"uuid":"\(Self.otherOrg)","capabilities":["billing"]}]
        """
        let resolver = resolver(Self.evaluator(
            organizationsEnvelope: ["status": 200, "retryAfter": NSNull(), "body": body],
            resourcePaths: ["/api/organizations/\(UUID().uuidString.lowercased())/usage"],
            callLog: { calls.append($0) }
        ))

        do {
            _ = try await resolver.organizationID(
                cacheKey: nil,
                excluding: Self.org,
                in: WKWebView()
            )
            XCTFail("expected noAlternativeOrganization")
        } catch let error as ClaudeOrganizationResolver.ResolutionError {
            XCTAssertEqual(error, .noAlternativeOrganization)
            XCTAssertFalse(
                calls.contains("scrape"),
                "the decoded list's judgment is final — the scrape must not run"
            )
        } catch {
            XCTFail("expected noAlternativeOrganization, got \(error)")
        }
    }

    /// An element without a `capabilities` array cannot be judged by the
    /// selection rules — it counts as undecodable, so the list refuses to
    /// select and falls to the scrape.
    func testMissingCapabilitiesRefusesSelection() async throws {
        let body = """
        [{"uuid":"\(Self.otherOrg)"},
         {"uuid":"\(UUID().uuidString.lowercased())","capabilities":["chat"]}]
        """
        let resolver = resolver(Self.evaluator(
            organizationsEnvelope: ["status": 200, "retryAfter": NSNull(), "body": body],
            resourcePaths: ["/api/organizations/\(Self.org)/usage"]
        ))

        let id = try await resolver.organizationID(cacheKey: nil, in: WKWebView())

        XCTAssertEqual(id, Self.org, "must come from the scrape, not the judgeable survivor")
    }

    /// Unanimity is judged over every org the page WITNESSED — the excluded
    /// org included. After A's usage 404, `[stale-A, incidental-B]` must NOT
    /// collapse to a fake "unanimous B": the page's testimony is conflicted,
    /// so the retry refuses rather than binding a snapshot to a workspace
    /// nothing proved active.
    func testExclusionDoesNotManufactureScrapeUnanimity() async {
        let resolver = resolver(Self.evaluator(
            organizationsEnvelope: ["status": 500, "retryAfter": NSNull(), "body": ""],
            resourcePaths: [
                "/api/organizations/\(Self.otherOrg)/prepaid/bundles",
                "/api/organizations/\(Self.org)/usage"
            ]
        ))

        do {
            _ = try await resolver.organizationID(
                cacheKey: nil,
                excluding: Self.org,
                in: WKWebView()
            )
            XCTFail("expected transport")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .transport)
        } catch {
            XCTFail("expected ProviderError.transport, got \(error)")
        }
    }

    /// A page that witnessed ONLY the excluded org has no alternative to
    /// offer — the veto yields `.none`, never a different guess.
    func testScrapeWitnessingOnlyExcludedOrgYieldsNothing() async {
        let resolver = resolver(Self.evaluator(
            organizationsEnvelope: ["status": 500, "retryAfter": NSNull(), "body": ""],
            resourcePaths: ["/api/organizations/\(Self.org)/usage"]
        ))

        do {
            _ = try await resolver.organizationID(
                cacheKey: nil,
                excluding: Self.org,
                in: WKWebView()
            )
            XCTFail("expected transport")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .transport)
        } catch {
            XCTFail("expected ProviderError.transport, got \(error)")
        }
    }

    /// The memoized fallback result is skipped when it equals the excluded
    /// org, so a 404-retry cannot be answered from the memo it invalidated.
    func testMemoizedFallbackIsSkippedWhenExcluded() async throws {
        let key = UUID()
        var listStatus = 200
        var scrape: [String] = []
        let client = WebUsageClient { script, arguments, _ in
            if script.contains("lastActiveOrg") { return NSNull() }
            if arguments["path"] as? String == "/api/organizations" {
                return [
                    "status": listStatus, "retryAfter": NSNull(),
                    "body": listStatus == 200
                        ? "[{\"uuid\":\"\(Self.org)\",\"capabilities\":[\"chat\"]}]"
                        : ""
                ]
            }
            if script.contains("getEntriesByType") { return scrape }
            XCTFail("unexpected evaluation: \(script.prefix(60))")
            return NSNull()
        }
        let resolver = ClaudeOrganizationResolver(client: client)

        let seeded = try await resolver.organizationID(cacheKey: key, in: WKWebView())
        XCTAssertEqual(seeded, Self.org)

        // Retry with the memoized org excluded and the list unknowable: the
        // memo must not answer, and the scrape resolves.
        listStatus = 500
        scrape = ["/api/organizations/\(Self.otherOrg)/usage"]
        let retried = try await resolver.organizationID(
            cacheKey: key,
            excluding: Self.org,
            in: WKWebView()
        )
        XCTAssertEqual(retried, Self.otherOrg)
    }


    /// Two overlapping keyed resolutions completing in REVERSE order: the
    /// newer one's result must survive in the memo, not be overwritten by
    /// the older one resuming late.
    func testOverlappingResolutionsReverseCompletionKeepNewestMemo() async throws {
        let key = UUID()
        var listCalls = 0
        var firstListGate: CheckedContinuation<Void, Never>?
        let client = WebUsageClient { script, arguments, _ in
            if script.contains("lastActiveOrg") { return NSNull() }
            if arguments["path"] as? String == "/api/organizations" {
                listCalls += 1
                if listCalls == 1 {
                    await withCheckedContinuation { (gate: CheckedContinuation<Void, Never>) in
                        firstListGate = gate
                    }
                    return [
                        "status": 200, "retryAfter": NSNull(),
                        "body": "[{\"uuid\":\"\(Self.org)\",\"capabilities\":[\"chat\"]}]"
                    ]
                }
                return [
                    "status": 200, "retryAfter": NSNull(),
                    "body": "[{\"uuid\":\"\(Self.otherOrg)\",\"capabilities\":[\"chat\"]}]"
                ]
            }
            XCTFail("unexpected evaluation: \(script.prefix(60))")
            return NSNull()
        }
        let resolver = ClaudeOrganizationResolver(client: client)

        let older = Task { @MainActor in
            try await resolver.organizationID(cacheKey: key, in: WKWebView())
        }
        while firstListGate == nil { await Task.yield() }
        let newer = try await resolver.organizationID(cacheKey: key, in: WKWebView())
        XCTAssertEqual(newer, Self.otherOrg)
        firstListGate?.resume()
        let olderResult = try await older.value
        XCTAssertEqual(olderResult, Self.org, "the older caller still gets ITS result")

        // The memo must hold the NEWER resolution's org: a memo hit here
        // returns otherOrg without a third list call.
        let third = try await resolver.organizationID(cacheKey: key, in: WKWebView())
        XCTAssertEqual(third, Self.otherOrg, "the older resolution must not overwrite the newer memo")
        XCTAssertEqual(listCalls, 2)
    }

    // Contract: a hung evaluation must surface as `.timedOut` untouched so
    // AccountSessionManager can recycle the web view.
    func testTimedOutPassesThroughUntouched() async {
        let client = WebUsageClient(
            evaluator: { _, _, _ in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return nil
            },
            sleep: { _ in }
        )
        let resolver = ClaudeOrganizationResolver(client: client)

        do {
            _ = try await resolver.organizationID(cacheKey: nil, in: WKWebView())
            XCTFail("expected timedOut")
        } catch let error as WebUsageClientError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("timedOut must pass through, got \(error)")
        }
    }

    func testCancellationPassesThrough() async {
        let client = WebUsageClient { _, _, _ in
            throw CancellationError()
        }
        let resolver = ClaudeOrganizationResolver(client: client)

        do {
            _ = try await resolver.organizationID(cacheKey: nil, in: WKWebView())
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}
