import WebKit
import XCTest
@testable import Ration

@MainActor
final class ClaudeProviderAdapterTests: XCTestCase {
    func testLiveProviderAdaptersIncludeClaude() {
        XCTAssertTrue(
            LiveProviderAdapters.all.map(\.provider).contains(.claude)
        )
    }

    /// 2026-08 frontend migration: `/settings/usage` now client-redirects to
    /// `/new#settings/usage`, so readiness is origin-based — any settled
    /// claude.ai page is a valid cookie/session host for the bridge scripts
    /// (which enforce the origin themselves at evaluation time).
    func testUsagePageReadyOnAnySettledClaudeAiPage() {
        XCTAssertTrue(
            ClaudeUsagePage.isReady(
                url: URL(string: "https://claude.ai/settings/usage"),
                isLoading: false
            )
        )
        XCTAssertTrue(
            ClaudeUsagePage.isReady(
                url: URL(string: "https://claude.ai/new#settings/usage"),
                isLoading: false
            ),
            "the post-migration redirect target must count as ready"
        )
        XCTAssertTrue(
            ClaudeUsagePage.isReady(
                url: URL(string: "https://claude.ai/login"),
                isLoading: false
            ),
            "a signed-out page is still a claude.ai origin — the usage fetch then surfaces 401 → Sign In"
        )
        XCTAssertFalse(
            ClaudeUsagePage.isReady(
                url: URL(string: "https://auth.claude.ai/settings/usage"),
                isLoading: false
            )
        )
        XCTAssertFalse(
            ClaudeUsagePage.isReady(
                url: URL(string: "http://claude.ai/new"),
                isLoading: false
            )
        )
        XCTAssertFalse(
            ClaudeUsagePage.isReady(url: URL(string: "about:blank"), isLoading: false)
        )
        XCTAssertFalse(ClaudeUsagePage.isReady(url: nil, isLoading: false))
        XCTAssertFalse(
            ClaudeUsagePage.isReady(
                url: URL(string: "https://claude.ai/new"),
                isLoading: true
            )
        )
    }

    func testVerifyPreservesCancellationFromResourceInspection() async {
        let client = WebUsageClient { _, _, _ in
            throw CancellationError()
        }
        let adapter = ClaudeProviderAdapter(
            client: client,
            prepareWebView: { _ in }
        )

        do {
            try await adapter.verifySession(in: WKWebView())
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected: refresh coordination relies on cancellation remaining cancellation.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    func testFetchAcceptsRecognizedWindowsWithoutScheduledResets() async throws {
        let organizationID = UUID().uuidString.lowercased()
        let client = WebUsageClient { script, arguments, _ in
            if script.contains("lastActiveOrg") {
                return organizationID
            }
            if (arguments["path"] as? String)?.hasPrefix("/api/organizations/\(organizationID)/usage") == true {
                return [
                    "status": 200,
                    "retryAfter": NSNull(),
                    "body": """
                    {
                      "five_hour": { "utilization": 5, "resets_at": null },
                      "seven_day": { "utilization": 53, "resets_at": null }
                    }
                    """
                ]
            }
            XCTFail("unexpected evaluation: \(script.prefix(60)) args=\(arguments)")
            return NSNull()
        }
        let accountID = UUID()
        let adapter = ClaudeProviderAdapter(
            client: client,
            prepareWebView: { _ in }
        )

        let snapshot = try await adapter.fetchUsage(
            accountID: accountID,
            in: WKWebView()
        )

        let fiveHour = try XCTUnwrap(snapshot.fiveHour)
        let weekly = try XCTUnwrap(snapshot.weekly)
        XCTAssertEqual(fiveHour.usedFraction, 0.05, accuracy: 0.0001)
        XCTAssertNil(fiveHour.resetsAt)
        XCTAssertEqual(weekly.usedFraction, 0.53, accuracy: 0.0001)
        XCTAssertNil(weekly.resetsAt)
        XCTAssertEqual(
            snapshot.organizationID, organizationID,
            "the snapshot must carry the org its data came from — auto-start fails closed without it"
        )
    }

    /// A single-organization account whose only org 404s on usage has no
    /// alternative to retry with: the resolver's exclusion leaves no
    /// candidate and throws transport, which the adapter must surface as
    /// integrationChanged (the endpoint moved) rather than an endless
    /// stale/transport retry.
    func testSingleOrgUsage404SurfacesIntegrationChangedNotTransport() async {
        let onlyOrg = UUID().uuidString.lowercased()
        var usageCalls = 0
        let client = WebUsageClient { script, arguments, _ in
            if script.contains("lastActiveOrg") { return onlyOrg }
            if script.contains("getEntriesByType") { return [String]() }
            if let path = arguments["path"] as? String {
                if path.contains("/usage") {
                    usageCalls += 1
                    return ["status": 404, "retryAfter": NSNull(), "body": ""]
                }
                // The account's one real org — the decoded list PROVES no
                // alternative exists once it is excluded.
                return [
                    "status": 200, "retryAfter": NSNull(),
                    "body": "[{\"uuid\":\"\(onlyOrg)\",\"capabilities\":[\"chat\"]}]"
                ]
            }
            XCTFail("unexpected evaluation: \(script.prefix(60))")
            return NSNull()
        }
        let adapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })

        do {
            _ = try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
            XCTFail("expected integrationChanged")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .integrationChanged)
            XCTAssertEqual(usageCalls, 1, "no alternative org exists — nothing to retry against")
        } catch {
            XCTFail("expected integrationChanged, got \(error)")
        }
    }

    /// A transient failure while resolving the RETRY org (list 5xx, scrape
    /// error) must stay `.transport` — only a DEFINITIVE "no alternative
    /// organization exists" may classify the 404 as integrationChanged.
    func testTransientRetryResolutionFailureStaysTransport() async {
        let onlyOrg = UUID().uuidString.lowercased()
        var usageCalls = 0
        let client = WebUsageClient { script, arguments, _ in
            if script.contains("lastActiveOrg") { return onlyOrg }
            if script.contains("getEntriesByType") {
                struct ScrapeDown: Error {}
                throw ScrapeDown()
            }
            if let path = arguments["path"] as? String {
                if path.contains("/usage") {
                    usageCalls += 1
                    return ["status": 404, "retryAfter": NSNull(), "body": ""]
                }
                return ["status": 503, "retryAfter": NSNull(), "body": ""]
            }
            XCTFail("unexpected evaluation: \(script.prefix(60))")
            return NSNull()
        }
        let adapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })

        do {
            _ = try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
            XCTFail("expected transport")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .transport, "a flaky retry must not read as a changed integration")
            XCTAssertEqual(usageCalls, 1)
        } catch {
            XCTFail("expected transport, got \(error)")
        }
    }

    func testLocalRedactedCaptureContainsVerifiedOrganizationsListShape() throws {
        let environmentKey = "RATION_CLAUDE_CONTRACT_FIXTURE"
        guard
            let path = ProcessInfo.processInfo.environment[environmentKey],
            FileManager.default.fileExists(atPath: path)
        else {
            throw XCTSkip("Set \(environmentKey) to a local sanitized capture")
        }

        let captures = try JSONDecoder().decode(
            [ProviderContractCapture].self,
            from: Data(contentsOf: URL(filePath: path))
        )
        guard
            let organizations = captures.first(where: {
                $0.provider == .claude
                    && $0.method == "GET"
                    && $0.path == "/api/organizations"
            })
        else {
            throw XCTSkip("Capture predates the organizations-list resolver — recapture to pin it")
        }
        guard case let .array(element) = organizations.shape,
              case let .object(fields) = element
        else {
            return XCTFail("Expected an array of organization objects")
        }
        // Pin the SHAPES the production decoder depends on, not mere key
        // presence: a uuid captured as a number or capabilities as an object
        // would be rejected by `OrganizationPayload` and must fail here too.
        XCTAssertEqual(fields["uuid"], .string)
        XCTAssertEqual(fields["capabilities"], .array(.string))
    }

    /// A 404 on the usage endpoint means the cached/resolved organization is no
    /// longer valid (org switch, revoked membership). The adapter must drop the
    /// cache, re-resolve ONCE, and retry; a second 404 with a freshly resolved
    /// organization means the endpoint itself moved → integrationChanged.
    func testUsage404InvalidatesCacheRetriesOnceThenSurfacesIntegrationChanged() async throws {
        let staleOrg = UUID().uuidString.lowercased()
        let freshOrg = UUID().uuidString.lowercased()
        var cookieReads = 0
        var usageCalls: [String] = []
        let client = WebUsageClient { script, arguments, _ in
            if script.contains("lastActiveOrg") {
                cookieReads += 1
                return cookieReads == 1 ? staleOrg : freshOrg
            }
            if let path = arguments["path"] as? String {
                usageCalls.append(path)
                if path.contains(staleOrg) {
                    return ["status": 404, "retryAfter": NSNull(), "body": ""]
                }
                return [
                    "status": 200,
                    "retryAfter": NSNull(),
                    "body": #"{"five_hour":{"utilization":5,"resets_at":null},"seven_day":null}"#
                ]
            }
            XCTFail("unexpected evaluation: \(script.prefix(60))")
            return NSNull()
        }
        let adapter = ClaudeProviderAdapter(client: client, prepareWebView: { _ in })

        let snapshot = try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())

        XCTAssertNotNil(snapshot.fiveHour)
        XCTAssertEqual(cookieReads, 2, "404 must invalidate and re-resolve exactly once")
        XCTAssertEqual(usageCalls.count, 2)

        // And when the retry 404s as well — against a genuinely DIFFERENT org
        // (the first is excluded, so the retry resolves via the scrape):
        // integrationChanged, not an endless loop.
        var usageNotFoundCalls = 0
        let scrapeOrg = UUID().uuidString.lowercased()
        let notFoundClient = WebUsageClient { script, arguments, _ in
            if script.contains("lastActiveOrg") { return staleOrg }
            if script.contains("getEntriesByType") {
                return ["/api/organizations/\(scrapeOrg)/usage"]
            }
            if let path = arguments["path"] as? String {
                if path.contains("/usage") {
                    usageNotFoundCalls += 1
                    return ["status": 404, "retryAfter": NSNull(), "body": ""]
                }
                return ["status": 200, "retryAfter": NSNull(), "body": "[]"]
            }
            XCTFail("unexpected evaluation: \(script.prefix(60))")
            return NSNull()
        }
        let failingAdapter = ClaudeProviderAdapter(client: notFoundClient, prepareWebView: { _ in })
        do {
            _ = try await failingAdapter.fetchUsage(accountID: UUID(), in: WKWebView())
            XCTFail("expected integrationChanged")
        } catch let error as ProviderError {
            XCTAssertEqual(error, .integrationChanged)
            XCTAssertEqual(usageNotFoundCalls, 2, "exactly one retry, no loop")
        }
    }

    func testLocalRedactedCaptureContainsVerifiedClaudeUsageShape() throws {
        let environmentKey = "RATION_CLAUDE_CONTRACT_FIXTURE"
        guard
            let path = ProcessInfo.processInfo.environment[environmentKey],
            FileManager.default.fileExists(atPath: path)
        else {
            throw XCTSkip("Set \(environmentKey) to a local sanitized capture")
        }

        let captures = try JSONDecoder().decode(
            [ProviderContractCapture].self,
            from: Data(contentsOf: URL(filePath: path))
        )
        let usage = try XCTUnwrap(
            captures.first {
                $0.provider == .claude
                    && $0.method == "GET"
                    && $0.path == "/api/organizations/:redacted/usage"
            }
        )
        guard case let .object(fields) = usage.shape else {
            return XCTFail("Expected the usage response to be an object")
        }

        XCTAssertNotNil(fields["five_hour"])
        XCTAssertNotNil(fields["seven_day"])
    }

    func testModelWeeklyDecodedFromScopedLimit() {
        let limits = [
            ClaudeLimitPayload(kind: "weekly_all", percent: 57, resetsAt: "2026-07-23T18:59:59Z",
                               scope: nil, isActive: true),
            ClaudeLimitPayload(kind: "weekly_scoped", percent: 46, resetsAt: "2026-07-23T18:59:59Z",
                               scope: .init(model: .init(id: nil, displayName: "Fable"), surface: nil),
                               isActive: false),
        ]
        let w = ClaudeProviderAdapter.modelWeeklyWindow(from: limits)
        XCTAssertNotNil(w)
        XCTAssertEqual(w?.kind, .modelWeekly)
        XCTAssertEqual(w?.remainingFraction ?? -1, 1 - 46.0/100, accuracy: 1e-9) // is_active:false still shown
        XCTAssertEqual(w?.label, "Fable")
        XCTAssertNotNil(w?.resetsAt)
    }

    func testNoScopedModelLimitYieldsNilModelWeekly() { // the Max-only gate
        let limits = [ClaudeLimitPayload(kind: "weekly_all", percent: 57, resetsAt: nil, scope: nil, isActive: true)]
        XCTAssertNil(ClaudeProviderAdapter.modelWeeklyWindow(from: limits))
        XCTAssertNil(ClaudeProviderAdapter.modelWeeklyWindow(from: nil))
        XCTAssertNil(ClaudeProviderAdapter.modelWeeklyWindow(from: []))
    }

    func testScopedLimitWithoutModelIsIgnored() {
        let limits = [ClaudeLimitPayload(kind: "weekly_scoped", percent: 46, resetsAt: nil, scope: nil, isActive: false)]
        XCTAssertNil(ClaudeProviderAdapter.modelWeeklyWindow(from: limits))
    }

    func testOutOfRangePercentIgnored() {
        let limits = [ClaudeLimitPayload(kind: "weekly_scoped", percent: 250, resetsAt: nil,
                                         scope: .init(model: .init(id: nil, displayName: "Fable"), surface: nil), isActive: false)]
        XCTAssertNil(ClaudeProviderAdapter.modelWeeklyWindow(from: limits))
    }

    func testMalformedLimitsEntryDoesNotSinkSnapshot() throws {
        // five_hour + seven_day valid; limits has ONE valid Fable entry and ONE
        // type-corrupt entry (percent as a string). Whole payload must still decode;
        // 5h/weekly present; the Fable window still extractable. Also exercises the
        // snake_case CodingKeys mapping (resets_at/is_active/display_name) via the
        // valid Fable entry.
        let json = """
        {"five_hour":{"utilization":17,"resets_at":null},
         "seven_day":{"utilization":57,"resets_at":null},
         "limits":[
           {"kind":"weekly_scoped","percent":"NOT_A_NUMBER","scope":null,"is_active":false},
           {"kind":"weekly_scoped","percent":46,"resets_at":"2026-07-23T18:59:59Z",
            "scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}
         ]}
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(ClaudeUsagePayload.self, from: json)
        XCTAssertNotNil(payload.fiveHour)
        XCTAssertNotNil(payload.sevenDay)
        let w = ClaudeProviderAdapter.modelWeeklyWindow(from: payload.limits)
        XCTAssertEqual(w?.label, "Fable")
        XCTAssertEqual(w?.remainingFraction ?? -1, 1 - 46.0/100, accuracy: 1e-9)
    }

    func testInvalidScopedEntryDoesNotMaskLaterValidEntry() {
        // Both entries are `weekly_scoped` with a non-empty Fable display name (so
        // both pass the kind+label test), but the FIRST has an out-of-range percent
        // (250) and the SECOND has a valid one (46). The old `first(where: kind &&
        // label)` THEN validate logic stops at the first kind+label match and
        // returns nil there — masking the later, fully valid entry. The fix must
        // keep scanning until it finds an entry that satisfies kind + label +
        // valid percent ALL together.
        let limits = [
            ClaudeLimitPayload(kind: "weekly_scoped", percent: 250, resetsAt: nil,
                               scope: .init(model: .init(id: nil, displayName: "Fable"), surface: nil),
                               isActive: true),
            ClaudeLimitPayload(kind: "weekly_scoped", percent: 46, resetsAt: "2026-07-23T18:59:59Z",
                               scope: .init(model: .init(id: nil, displayName: "Fable"), surface: nil),
                               isActive: false),
        ]
        let w = ClaudeProviderAdapter.modelWeeklyWindow(from: limits)
        XCTAssertNotNil(w, "the later valid entry must not be masked by the earlier invalid one")
        XCTAssertEqual(w?.label, "Fable")
        XCTAssertEqual(w?.remainingFraction ?? -1, 1 - 46.0/100, accuracy: 1e-9)
    }

    func testMalformedLimitsArrayShapeYieldsNilLimitsButKeepsWindows() throws {
        // limits present but NOT an array → limits nil, 5h/weekly survive.
        let json = """
        {"five_hour":{"utilization":17,"resets_at":null},
         "seven_day":{"utilization":57,"resets_at":null},
         "limits":{"unexpected":"object"}}
        """.data(using: .utf8)!
        let payload = try JSONDecoder().decode(ClaudeUsagePayload.self, from: json)
        XCTAssertNotNil(payload.fiveHour)
        XCTAssertNil(ClaudeProviderAdapter.modelWeeklyWindow(from: payload.limits))
    }

    // A hung JS-bridge evaluation must surface as `.timedOut`, not get
    // wrapped into `.transport` by the resource-path poller's catch-all —
    // `AccountSessionManager` keys its web-view recycle on `.timedOut`.
    @MainActor
    func testTimedOutPassesThroughUntouched() async {
        let adapter = ClaudeProviderAdapter(
            client: WebUsageClient(
                evaluator: { _, _, _ in
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                    return nil
                },
                sleep: { _ in }
            ),
            prepareWebView: { _ in }
        )
        do {
            _ = try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
            XCTFail("expected timedOut")
        } catch let error as WebUsageClientError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("timedOut must pass through, got \(error)")
        }
    }
}
