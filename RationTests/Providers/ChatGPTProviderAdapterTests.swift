import WebKit
import XCTest
@testable import Ration

@MainActor
final class ChatGPTProviderAdapterTests: XCTestCase {
    /// Origin-based readiness: any settled chatgpt.com page is a valid
    /// cookie/session host — the fetch script enforces the origin itself and
    /// turns a token-less `/api/auth/session` into a 401 → Sign In badge.
    /// (The old exact-path gate turned an expired session into an endless
    /// `stale` badge: logged out, `/codex/settings/usage` redirects to `/`,
    /// the gate never matched, and the 401 path was unreachable.)
    func testUsagePageReadyOnAnySettledChatGPTPage() {
        XCTAssertTrue(
            ChatGPTUsagePage.isReady(
                url: URL(
                    string: "https://chatgpt.com/codex/cloud/settings/analytics#usage"
                ),
                isLoading: false
            )
        )
        XCTAssertTrue(
            ChatGPTUsagePage.isReady(
                url: URL(string: "https://chatgpt.com/codex/settings/usage"),
                isLoading: false
            )
        )
        XCTAssertTrue(
            ChatGPTUsagePage.isReady(
                url: URL(string: "https://chatgpt.com/"),
                isLoading: false
            ),
            "the signed-out redirect target must count as ready so the 401 path can run"
        )
        XCTAssertFalse(
            ChatGPTUsagePage.isReady(
                url: URL(
                    string: "https://auth.chatgpt.com/codex/cloud/settings/analytics#usage"
                ),
                isLoading: false
            )
        )
        XCTAssertFalse(
            ChatGPTUsagePage.isReady(
                url: URL(string: "http://chatgpt.com/"),
                isLoading: false
            )
        )
        XCTAssertFalse(
            ChatGPTUsagePage.isReady(url: URL(string: "about:blank"), isLoading: false)
        )
        XCTAssertFalse(ChatGPTUsagePage.isReady(url: nil, isLoading: false))
        XCTAssertFalse(
            ChatGPTUsagePage.isReady(
                url: URL(string: "https://chatgpt.com/"),
                isLoading: true
            )
        )
    }

    func testVerifyPreservesCancellationFromUsageFetch() async {
        let client = WebUsageClient { _, _, _ in
            throw CancellationError()
        }
        let adapter = ChatGPTProviderAdapter(
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

    func testFetchClassifiesWeeklyOnlyPrimaryWindowByDuration() async throws {
        let client = WebUsageClient { _, _, _ in
            [
                "status": 200,
                "retryAfter": NSNull(),
                "body": """
                {
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 72,
                      "limit_window_seconds": 604800,
                      "reset_at": 1784487780
                    },
                    "secondary_window": null
                  }
                }
                """
            ]
        }
        let adapter = ChatGPTProviderAdapter(
            client: client,
            prepareWebView: { _ in }
        )

        let snapshot = try await adapter.fetchUsage(
            accountID: UUID(),
            in: WKWebView()
        )

        XCTAssertNil(snapshot.fiveHour)
        let weekly = try XCTUnwrap(snapshot.weekly)
        XCTAssertEqual(weekly.usedFraction, 0.72, accuracy: 0.0001)
        XCTAssertEqual(
            weekly.resetsAt,
            Date(timeIntervalSince1970: 1_784_487_780)
        )
    }

    private func fetchSnapshot(planTypeJSON: String) async throws -> UsageSnapshot {
        let client = WebUsageClient { _, _, _ in
            [
                "status": 200,
                "retryAfter": NSNull(),
                "body": """
                {
                  \(planTypeJSON)
                  "rate_limit": {
                    "primary_window": {
                      "used_percent": 10,
                      "limit_window_seconds": 604800,
                      "reset_at": 1784487780
                    },
                    "secondary_window": null
                  }
                }
                """
            ]
        }
        let adapter = ChatGPTProviderAdapter(client: client, prepareWebView: { _ in })
        return try await adapter.fetchUsage(accountID: UUID(), in: WKWebView())
    }

    func testFetchReadsPlanType() async throws {
        let prolite = try await fetchSnapshot(planTypeJSON: "\"plan_type\": \"prolite\",")
        XCTAssertEqual(prolite.planDetection, .tier(.chatGPTPro5x))
        let team = try await fetchSnapshot(planTypeJSON: "\"plan_type\": \"team\",")
        XCTAssertEqual(team.planDetection, .unrecognized)
        let absent = try await fetchSnapshot(planTypeJSON: "")
        XCTAssertNil(absent.planDetection)
        let wrongShape = try await fetchSnapshot(planTypeJSON: "\"plan_type\": 7,")
        XCTAssertNil(wrongShape.planDetection, "a wrong-shaped plan never fails the usage decode")
        XCTAssertNotNil(wrongShape.weekly)
    }

    func testLocalRedactedCaptureContainsVerifiedChatGPTUsageShape() throws {
        let environmentKey = "RATION_CHATGPT_CONTRACT_FIXTURE"
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
                $0.provider == .chatGPT
                    && $0.method == "GET"
                    && $0.path == "/backend-api/wham/usage"
            }
        )
        guard case let .object(fields) = usage.shape else {
            return XCTFail("Expected the usage response to be an object")
        }

        XCTAssertNotNil(fields["plan_type"])
        XCTAssertNotNil(fields["rate_limit"])
    }

    // A hung JS-bridge evaluation must surface as `.timedOut`, not get
    // wrapped into `.transport` by `responseBody`'s catch-all —
    // `AccountSessionManager` keys its web-view recycle on `.timedOut`.
    func testTimedOutPassesThroughUntouched() async {
        let adapter = ChatGPTProviderAdapter(
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
