import WebKit
import XCTest
@testable import Ration

@MainActor
final class ClaudeMessageSenderTests: XCTestCase {
    private func makeSender(_ stub: WebEvalStub) -> ClaudeMessageSender {
        ClaudeMessageSender(client: WebUsageClient(evaluator: stub.evaluate))
    }

    func testPrepareDiscoversOrgAndLiveModel() async throws {
        let stub = WebEvalStub()
        let prepared = try await makeSender(stub).prepare(in: WKWebView(frame: .zero))

        XCTAssertEqual(prepared.organizationID, stub.organizationID)
        XCTAssertEqual(prepared.model, "claude-test-model")
    }

    /// Page entries naming TWO different workspaces prove nothing about which
    /// one is active — unbound discovery must refuse (the resolver's
    /// unanimity rule) instead of ranking heuristics for an irreversible
    /// send. (Pre-2026-08 behavior preferred the `/usage` entry; the
    /// frontend migration removed that signal's reliability.)
    func testMixedWorkspacePageEvidenceRefusesUnboundDiscovery() async {
        let stub = WebEvalStub()
        stub.resourcePaths = [
            "/api/organizations/99999999-0000-0000-0000-000000000000/chat_conversations",
            "/api/organizations/\(stub.organizationID)/usage"
        ]
        await assertThrows(.organizationNotFound) {
            _ = try await self.makeSender(stub).prepare(in: WKWebView(frame: .zero))
        }
    }

    func testFirstSendCreatesConversationThenCompletes() async throws {
        let stub = WebEvalStub()
        let sender = makeSender(stub)
        let prepared = try await sender.prepare(in: WKWebView(frame: .zero))

        let conversation = try await sender.send(
            prepared: prepared,
            conversationID: nil,
            prompt: "hi",
            in: WKWebView(frame: .zero)
        )

        // Two POSTs: create the conversation, then send the completion.
        XCTAssertEqual(stub.postPaths.count, 2)
        XCTAssertEqual(
            stub.postPaths.first,
            "/api/organizations/\(stub.organizationID)/chat_conversations"
        )
        XCTAssertEqual(
            stub.postPaths.last,
            "/api/organizations/\(stub.organizationID)/chat_conversations/"
                + "\(conversation.uuidString.lowercased())/completion"
        )
        // The create body carries the client-generated uuid; the completion body
        // carries the prompt/model.
        XCTAssertTrue(stub.postBodies.first?.contains(conversation.uuidString.lowercased()) == true)
        XCTAssertTrue(stub.postBodies.last?.contains("\"prompt\":\"hi\"") == true)
        XCTAssertTrue(stub.postBodies.last?.contains("\"model\":\"claude-test-model\"") == true)
    }

    func testReusesStoredConversationWithoutCreating() async throws {
        let stub = WebEvalStub()
        let sender = makeSender(stub)
        let prepared = try await sender.prepare(in: WKWebView(frame: .zero))
        let existing = UUID()

        let used = try await sender.send(
            prepared: prepared,
            conversationID: existing,
            in: WKWebView(frame: .zero)
        )

        XCTAssertEqual(used, existing)
        // Only the completion POST — no create for an existing conversation.
        XCTAssertEqual(stub.postPaths.count, 1)
        XCTAssertTrue(stub.postPaths[0].hasSuffix("/completion"))
        XCTAssertTrue(stub.postPaths[0].contains(existing.uuidString.lowercased()))
    }

    func testDeletedConversation404CreatesFreshAndRetries() async throws {
        let stub = WebEvalStub()
        // completion(404) → create(200) → completion(200)
        stub.postStatuses = [404, 200, 200]
        let sender = makeSender(stub)
        let prepared = try await sender.prepare(in: WKWebView(frame: .zero))
        let deleted = UUID()

        let used = try await sender.send(
            prepared: prepared,
            conversationID: deleted,
            in: WKWebView(frame: .zero)
        )

        XCTAssertNotEqual(used, deleted)
        XCTAssertEqual(stub.postPaths.count, 3)
        XCTAssertTrue(stub.postPaths[0].contains(deleted.uuidString.lowercased()))
        XCTAssertTrue(stub.postPaths[1].hasSuffix("/chat_conversations"))
        XCTAssertTrue(stub.postPaths[2].contains(used.uuidString.lowercased()))
    }

    func testMissingOrganizationThrows() async throws {
        let stub = WebEvalStub()
        stub.resourcePaths = []
        await assertThrows(.organizationNotFound) {
            _ = try await self.makeSender(stub).prepare(in: WKWebView(frame: .zero))
        }
    }

    func testModelDiscoveryBoundsTheListRead() async throws {
        // Regression: a heavy account's full conversation list can exceed the
        // 1 MB response cap, which zeroes the body and (pre-fix) surfaced as
        // `modelNotFound` forever. The read must be bounded with `?limit=` on the
        // exact usage org.
        let stub = WebEvalStub()
        _ = try await makeSender(stub).prepare(in: WKWebView(frame: .zero))
        let conversationsGet = stub.getPaths.first { $0.contains("/chat_conversations") }
        XCTAssertEqual(
            conversationsGet,
            "/api/organizations/\(stub.organizationID)/chat_conversations?limit=10"
        )
    }

    func testEmptyConversationListFallsBackToDefaultModel() async throws {
        // A brand-new account with no conversations must not block auto-start:
        // discovery falls back to a known-good default model.
        let stub = WebEvalStub()
        stub.conversationsJSON = "[]"
        let prepared = try await makeSender(stub).prepare(in: WKWebView(frame: .zero))
        XCTAssertEqual(prepared.model, ClaudeMessageSender.fallbackModel)
    }

    func testImplausibleModelIsRejectedAndValidOneChosen() async throws {
        let stub = WebEvalStub()
        // A hostile/changed page returns a first conversation whose `model` is
        // an injection-shaped string, then a legitimate one. the implausible
        // value is skipped (not driven into the irreversible send) and the next
        // valid model is used.
        stub.conversationsJSON = """
        [{"model":"evil model with spaces/and slashes","uuid":"a"},\
        {"model":"claude-sonnet-4-5-20250929","uuid":"b"}]
        """
        let prepared = try await makeSender(stub).prepare(in: WKWebView(frame: .zero))
        XCTAssertEqual(prepared.model, "claude-sonnet-4-5-20250929")
    }

    func testAllImplausibleModelsFallBackToDefault() async throws {
        // No conversation carries a usable model (all implausible): fall back to
        // the default rather than throwing — the implausible values are still
        // never driven into the send.
        let stub = WebEvalStub()
        let huge = String(repeating: "x", count: 5_000)
        stub.conversationsJSON = "[{\"model\":\"\(huge)\",\"uuid\":\"a\"}]"
        let prepared = try await makeSender(stub).prepare(in: WKWebView(frame: .zero))
        XCTAssertEqual(prepared.model, ClaudeMessageSender.fallbackModel)
    }

    func testNonASCIIHomoglyphModelFallsBackToDefault() async throws {
        let stub = WebEvalStub()
        // "claude" with Cyrillic homoglyphs (с, а, е, ...) — passes a naive
        // isLetter check but violates the ASCII-only model-id contract, so
        // it is rejected and the default is used instead.
        stub.conversationsJSON =
            #"[{"model":"сlаudе-modеl","uuid":"a"}]"#
        let prepared = try await makeSender(stub).prepare(in: WKWebView(frame: .zero))
        XCTAssertEqual(prepared.model, ClaudeMessageSender.fallbackModel)
    }

    func testOversizeConversationReadSurfacesAsTransport() async throws {
        // The 1 MB cap returns the sentinel `status:0` with an empty body. That
        // is a transient read failure, not "no model" — it must surface as
        // `.transport` (retry), never `.modelNotFound`.
        let stub = WebEvalStub()
        stub.conversationsStatus = 0
        await assertThrows(.transport) {
            _ = try await self.makeSender(stub).prepare(in: WKWebView(frame: .zero))
        }
    }

    func testServerErrorConversationReadSurfacesAsRejected() async throws {
        // A real HTTP status is preserved so the banner can distinguish it from
        // the transient cap sentinel.
        let stub = WebEvalStub()
        stub.conversationsStatus = 500
        await assertThrows(.rejected(status: 500)) {
            _ = try await self.makeSender(stub).prepare(in: WKWebView(frame: .zero))
        }
    }

    func testAuthFailureOnConversationReadSurfacesAsRejected() async throws {
        // A genuine 401/403 on the model-discovery read must be preserved as
        // `.rejected(status:)` so the banner tells the user to sign in — not
        // masked as a transient retry.
        for status in [401, 403] {
            let stub = WebEvalStub()
            stub.conversationsStatus = status
            await assertThrows(.rejected(status: status)) {
                _ = try await self.makeSender(stub).prepare(in: WKWebView(frame: .zero))
            }
        }
    }

    func testUnexpectedResponseShapeThrowsRatherThanSilentlyFallingBack() async throws {
        // A 2xx whose body is not the expected JSON array is a changed/unknown
        // shape. It must surface (`modelNotFound`), never silently drive the
        // irreversible send with the default model.
        let stub = WebEvalStub()
        stub.conversationsJSON = #"{"conversations": []}"#
        await assertThrows(.modelNotFound) {
            _ = try await self.makeSender(stub).prepare(in: WKWebView(frame: .zero))
        }
    }

    func testRejectedCompletionThrows() async throws {
        let stub = WebEvalStub()
        stub.postStatuses = [403]
        let sender = makeSender(stub)
        let prepared = try await sender.prepare(in: WKWebView(frame: .zero))

        await assertThrows(.rejected(status: 403)) {
            _ = try await sender.send(
                prepared: prepared,
                conversationID: UUID(),
                in: WKWebView(frame: .zero)
            )
        }
    }

    func testFallbackModelIsSentInCompletionBody() async throws {
        // End-to-end: an empty account falls back to the default model, and that
        // model is what actually reaches the irreversible completion POST.
        let stub = WebEvalStub()
        stub.conversationsJSON = "[]"
        let sender = makeSender(stub)
        let prepared = try await sender.prepare(in: WKWebView(frame: .zero))
        _ = try await sender.send(
            prepared: prepared,
            conversationID: UUID(),
            in: WKWebView(frame: .zero)
        )
        XCTAssertTrue(
            stub.postBodies.last?.contains(
                "\"model\":\"\(ClaudeMessageSender.fallbackModel)\""
            ) == true,
            "completion body must carry the fallback model (\(stub.postBodies.last ?? "nil"))"
        )
    }

    // A hung JS-bridge evaluation must surface as `.timedOut`, not get
    // wrapped into `.transport` by `createConversation`'s catch-all —
    // `AccountSessionManager` keys its web-view recycle on `.timedOut`.
    //
    // NOTE: this targets `send(...)`, not `prepare(in:)` as the brief's
    // illustrative snippet originally suggested. `send`'s
    // `createConversation`/`postCompletion` are the two genuine
    // `catch { throw SendError.transport }` sites this task fixes;
    // `Prepared` is constructed directly to reach `send` without depending on
    // `prepare` succeeding first. `prepare`'s own `.timedOut` passthrough
    // (through `discoverOrganizationID`) is covered separately below by
    // `testPrepareSurfacesTimedOutFromOrganizationDiscovery`.
    @MainActor
    func testTimedOutPassesThroughUntouched() async {
        let sender = ClaudeMessageSender(
            client: WebUsageClient(
                evaluator: { _, _, _ in
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                    return nil
                },
                sleep: { _ in }
            )
        )
        let prepared = ClaudeMessageSender.Prepared(
            organizationID: "123e4567-e89b-12d3-a456-426614174000",
            model: "claude-test-model"
        )
        do {
            _ = try await sender.send(
                prepared: prepared,
                conversationID: nil,
                in: WKWebView(frame: .zero)
            )
            XCTFail("expected timedOut")
        } catch let error as WebUsageClientError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("timedOut must pass through, got \(error)")
        }
    }

    // Fix-report follow-up: `discoverOrganizationID` used to swallow
    // EVERY error from `client.resourcePaths` — including `.timedOut` — via
    // a bare `try?`, degrading a hang to `SendError.organizationNotFound`.
    // `AccountSessionManager`'s web-view recycle keys specifically on
    // `.timedOut` reaching the caller, so a hang during org-discovery would
    // silently miss the recycle. `prepare(in:)` must now surface `.timedOut`
    // raw from this path, exactly as the brief's original illustrative
    // snippet expected.
    @MainActor
    func testPrepareSurfacesTimedOutFromOrganizationDiscovery() async {
        let sender = ClaudeMessageSender(
            client: WebUsageClient(
                evaluator: { _, _, _ in
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                    return nil
                },
                sleep: { _ in }
            )
        )
        do {
            _ = try await sender.prepare(in: WKWebView(frame: .zero))
            XCTFail("expected timedOut")
        } catch let error as WebUsageClientError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("timedOut must pass through, got \(error)")
        }
    }

    /// The irreversible send must target the organization the account's last
    /// SUCCESSFUL usage fetch actually used — not whatever discovery answers
    /// seconds later (a workspace switch between snapshot and send must not
    /// redirect the keep-alive to a workspace the snapshot never saw).
    /// A bound prepare uses the triggering snapshot's org DIRECTLY: no org
    /// discovery runs at all, so no page state or shared cache can redirect
    /// the irreversible send. (Only the model-discovery GET touches the
    /// bridge.)
    func testBoundPrepareUsesSnapshotOrganizationWithoutDiscovery() async throws {
        let stub = WebEvalStub()
        let boundOrg = UUID().uuidString.lowercased()
        // Discovery, if it ran, would find a DIFFERENT org.
        stub.resourcePaths = ["/api/organizations/\(stub.organizationID)/usage"]

        let prepared = try await makeSender(stub).prepare(
            boundToOrganizationID: boundOrg,
            in: WKWebView(frame: .zero)
        )

        XCTAssertEqual(prepared.organizationID, boundOrg)
        XCTAssertEqual(
            stub.getPaths.filter { $0.contains("/chat_conversations") }.count,
            stub.getPaths.count,
            "a bound prepare may only fetch model discovery, never org discovery"
        )
    }

    /// The explicitly UNBOUND call (nil — the manual debug send after a
    /// failed warm-up) is the only path that uses live discovery.
    func testUnboundPrepareUsesLiveDiscovery() async throws {
        let stub = WebEvalStub()
        let prepared = try await makeSender(stub).prepare(
            boundToOrganizationID: nil,
            in: WKWebView(frame: .zero)
        )
        XCTAssertEqual(prepared.organizationID, stub.organizationID)
    }

    func testFallbackModelSatisfiesPlausibilityContract() {
        // The fallback bypasses the per-conversation plausibility check, so the
        // constant itself must satisfy the same ASCII/length contract that
        // guards every model string driven into the irreversible send.
        XCTAssertTrue(
            ClaudeMessageSender.isPlausibleModel(ClaudeMessageSender.fallbackModel)
        )
    }

    private func assertThrows(
        _ expected: ClaudeMessageSender.SendError,
        _ operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected)")
        } catch let error as ClaudeMessageSender.SendError {
            XCTAssertEqual(error, expected)
        } catch {
            XCTFail("Unexpected error \(error)")
        }
    }
}

@MainActor
private final class WebEvalStub {
    let organizationID = "123e4567-e89b-12d3-a456-426614174000"
    lazy var resourcePaths: [String] = ["/api/organizations/\(organizationID)/usage"]
    var conversationsJSON = #"[{"model":"claude-test-model","uuid":"abc"}]"#
    /// Status returned for the conversations (model-discovery) GET. `0` mimics
    /// the 1 MB-cap sentinel; a 5xx mimics a transient server error.
    var conversationsStatus = 200
    var postStatuses: [Int] = [200]
    private(set) var postPaths: [String] = []
    private(set) var postBodies: [String] = []
    private(set) var getPaths: [String] = []

    func evaluate(
        script: String,
        arguments: [String: Any],
        webView: WKWebView
    ) async throws -> Any? {
        if script.contains("lastActiveOrg") {
            // No cookie in the stubbed page: the resolver falls through to the
            // organizations list and then the resource-entry scrape below.
            return NSNull()
        }
        if script.contains("performance.getEntriesByType") {
            return resourcePaths
        }
        if script.contains("method: \"POST\"") {
            postPaths.append(arguments["path"] as? String ?? "")
            postBodies.append(arguments["bodyJSON"] as? String ?? "")
            let index = postPaths.count - 1
            let status = index < postStatuses.count
                ? postStatuses[index]
                : postStatuses.last ?? 200
            return ["status": status, "retryAfter": NSNull(), "body": ""]
        }
        getPaths.append(arguments["path"] as? String ?? "")
        return ["status": conversationsStatus, "retryAfter": NSNull(), "body": conversationsJSON]
    }
}
