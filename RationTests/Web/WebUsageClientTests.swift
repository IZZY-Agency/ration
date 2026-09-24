import WebKit
import XCTest
@testable import Ration

final class WebUsageClientTests: XCTestCase {
    @MainActor
    func testFetchPassesPathAsArgumentAndReturnsSafeEnvelope() async throws {
        let webView = WKWebView()
        let client = WebUsageClient { script, arguments, receivedWebView in
            XCTAssertTrue(script.contains("fetch(path"))
            // Origin guard is enforced inside the evaluated script and the
            // expected origin is passed as an argument. Assert the guard
            // appears BEFORE the credentialed `fetch(` — a guard moved after the
            // request would not protect it, and must fail this test.
            let guardRange = try XCTUnwrap(
                script.range(of: "location.origin !== expectedOrigin")
            )
            let fetchRange = try XCTUnwrap(script.range(of: "fetch(path"))
            XCTAssertTrue(guardRange.lowerBound < fetchRange.lowerBound)
            XCTAssertEqual(arguments["path"] as? String, "/verified/usage")
            XCTAssertEqual(
                arguments["expectedOrigin"] as? String,
                "https://claude.ai"
            )
            XCTAssertTrue(receivedWebView === webView)
            return [
                "status": 200,
                "retryAfter": "120",
                "body": "{\"five_hour\":null}"
            ]
        }

        let response = try await client.fetch(
            path: "/verified/usage",
            expectedOrigin: "https://claude.ai",
            in: webView
        )

        XCTAssertEqual(
            response,
            WebResponseEnvelope(
                status: 200,
                retryAfter: "120",
                body: "{\"five_hour\":null}"
            )
        )
    }

    @MainActor
    func testFetchScriptReadsBodyWithBoundedReader() async throws {
        let client = WebUsageClient { script, _, _ in
            // The body is read through the bounded streaming reader, not an
            // uncapped response.text().
            XCTAssertTrue(script.contains("__readBounded"))
            XCTAssertFalse(script.contains("const body = await response.text()"))
            return ["status": 200, "retryAfter": NSNull(), "body": "{}"]
        }
        _ = try await client.fetch(
            path: "/x",
            expectedOrigin: "https://claude.ai",
            in: WKWebView()
        )
    }

    @MainActor
    func testFetchRejectsOversizedBodyNatively() async {
        let oversized = String(
            repeating: "a",
            count: WebUsageClient.maxResponseBytes + 1
        )
        let client = WebUsageClient { _, _, _ in
            ["status": 200, "retryAfter": NSNull(), "body": oversized]
        }
        do {
            _ = try await client.fetch(
                path: "/x",
                expectedOrigin: "https://claude.ai",
                in: WKWebView()
            )
            XCTFail("Expected an oversized body to be rejected")
        } catch {
            XCTAssertEqual(error as? WebUsageClientError, .invalidResponse)
        }
    }

    @MainActor
    func testFetchRejectsUnexpectedJavaScriptResult() async {
        let client = WebUsageClient { _, _, _ in "not a dictionary" }

        do {
            _ = try await client.fetch(
                path: "/verified/usage",
                expectedOrigin: "https://claude.ai",
                in: WKWebView()
            )
            XCTFail("Expected invalid response error")
        } catch {
            XCTAssertEqual(error as? WebUsageClientError, .invalidResponse)
        }
    }

    @MainActor
    func testChatGPTFetchKeepsAuthenticationInsidePageScript() async throws {
        let webView = WKWebView()
        let client = WebUsageClient { script, arguments, receivedWebView in
            XCTAssertTrue(script.contains("/api/auth/session"))
            XCTAssertTrue(
                script.contains("location.origin !== \"https://chatgpt.com\"")
            )
            XCTAssertTrue(script.contains("/backend-api/wham/usage"))
            XCTAssertTrue(script.contains("Authorization"))
            XCTAssertTrue(script.contains("ChatGPT-Account-ID"))
            XCTAssertFalse(script.contains("console."))
            XCTAssertTrue(arguments.isEmpty)
            XCTAssertTrue(receivedWebView === webView)
            return [
                "status": 200,
                "retryAfter": NSNull(),
                "body": "{}"
            ]
        }

        let response = try await client.fetchChatGPT(in: webView)

        XCTAssertEqual(response.usage.status, 200)
        XCTAssertEqual(response.usage.body, "{}")
        XCTAssertNil(response.resetCredits)
    }

    @MainActor
    func testResourcePathsReturnOnlyEvaluatorPathnames() async throws {
        let webView = WKWebView()
        let client = WebUsageClient { script, arguments, receivedWebView in
            XCTAssertTrue(script.contains("performance.getEntriesByType"))
            XCTAssertTrue(script.contains("url.pathname"))
            XCTAssertFalse(script.contains(".compactMap"))
            XCTAssertTrue(script.contains(".map("))
            XCTAssertTrue(script.contains(".filter("))
            // Origin guard enforced inside the script, BEFORE it reads
            // `performance` resource entries.
            let guardRange = try XCTUnwrap(
                script.range(of: "location.origin !== expectedOrigin")
            )
            let performanceRange = try XCTUnwrap(
                script.range(of: "performance.getEntriesByType")
            )
            XCTAssertTrue(guardRange.lowerBound < performanceRange.lowerBound)
            XCTAssertEqual(
                arguments["expectedOrigin"] as? String,
                "https://claude.ai"
            )
            XCTAssertTrue(receivedWebView === webView)
            return ["/resource/path"]
        }

        let paths = try await client.resourcePaths(
            expectedOrigin: "https://claude.ai",
            in: webView
        )

        XCTAssertEqual(
            paths,
            ["/resource/path"]
        )
    }

    /// The origin guard is the security boundary now that the native
    /// readiness gates are origin-only: the cookie read must be refused
    /// before `document.cookie` is ever touched on a foreign origin, and the
    /// expected origin must come from the caller, not the page.
    @MainActor
    func testLastActiveOrganizationCookieScriptGuardsOriginBeforeCookieRead() async throws {
        var capturedScript: String?
        var capturedArguments: [String: Any] = [:]
        let client = WebUsageClient { script, arguments, _ in
            capturedScript = script
            capturedArguments = arguments
            return "20553b43-bbde-4a26-95e3-b385724ddcd4"
        }

        let value = try await client.lastActiveOrganizationCookie(
            expectedOrigin: "https://claude.ai",
            in: WKWebView(frame: .zero)
        )

        XCTAssertEqual(value, "20553b43-bbde-4a26-95e3-b385724ddcd4")
        XCTAssertEqual(capturedArguments["expectedOrigin"] as? String, "https://claude.ai")
        let script = try XCTUnwrap(capturedScript)
        // The guard must be the script's FIRST statement and must RETURN —
        // not merely appear somewhere before the cookie read.
        XCTAssertTrue(
            script.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(
                """
                if (location.origin !== expectedOrigin) {
                    return null;
                }
                """
            ),
            "the origin guard must open the script and return before anything else runs"
        )
        XCTAssertNotNil(script.range(of: "document.cookie"))
    }

    @MainActor
    func testLastActiveOrganizationCookieNonStringOrEmptyResultIsNil() async throws {
        for stubbed in [NSNull() as Any?, ["status": 200] as Any?, "" as Any?, nil] {
            let client = WebUsageClient { _, _, _ in stubbed }
            let value = try await client.lastActiveOrganizationCookie(
                expectedOrigin: "https://claude.ai",
                in: WKWebView(frame: .zero)
            )
            XCTAssertNil(value)
        }
    }

    @MainActor
    func testHungEvaluatorTimesOutDeterministically() async {
        // Evaluator never resumes; the injected sleep returns immediately, so
        // the timeout side of the race wins deterministically.
        let client = WebUsageClient(
            evaluator: { _, _, _ in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                return nil
            },
            sleep: { _ in }
        )
        do {
            _ = try await client.fetch(
                path: "/api/x",
                expectedOrigin: "https://claude.ai",
                in: WKWebView(frame: .zero)
            )
            XCTFail("expected timedOut")
        } catch let error as WebUsageClientError {
            XCTAssertEqual(error, .timedOut)
        } catch {
            XCTFail("expected WebUsageClientError.timedOut, got \(error)")
        }
    }

    @MainActor
    func testFastEvaluatorWinsWhenSleepNeverReturns() async throws {
        // Operation resolves; the sleep side never returns → no timeout.
        let client = WebUsageClient(
            evaluator: { _, _, _ in
                ["status": 200, "retryAfter": NSNull(), "body": "{}"]
            },
            sleep: { _ in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
            }
        )
        let envelope = try await client.fetch(
            path: "/api/x",
            expectedOrigin: "https://claude.ai",
            in: WKWebView(frame: .zero)
        )
        XCTAssertEqual(envelope.status, 200)
    }

    @MainActor
    func testLateEvaluatorResultAfterTimeoutIsDiscarded() async throws {
        // The evaluator resumes AFTER the timeout already fired: its late
        // result must be discarded without a second continuation resume
        // (no crash, no envelope surfacing).
        var release: CheckedContinuation<Void, Never>?
        let client = WebUsageClient(
            evaluator: { _, _, _ in
                await withCheckedContinuation { release = $0 }
                return ["status": 200, "retryAfter": NSNull(), "body": "{}"]
            },
            sleep: { _ in }
        )
        do {
            _ = try await client.postJSON(
                path: "/api/x",
                bodyJSON: "{}",
                in: WKWebView(frame: .zero)
            )
            XCTFail("expected timedOut")
        } catch let error as WebUsageClientError {
            XCTAssertEqual(error, .timedOut)
        }
        // Let the abandoned evaluator finish now; nothing must blow up.
        // Unwrap so this test cannot silently pass
        // without ever exercising the late-delivery path (e.g. if the
        // evaluator never reached its continuation).
        let unwrappedRelease = try XCTUnwrap(
            release,
            "the evaluator must have reached its continuation for this test to be meaningful"
        )
        unwrappedRelease.resume()
        await Task.yield()
    }

    /// A vetoing `mayDispatch` stops the POST before WebKit sees it.
    @MainActor
    func testPostJSONVetoedByMayDispatchNeverEvaluates() async throws {
        var evaluations = 0
        let client = WebUsageClient(
            evaluator: { _, _, _ in
                evaluations += 1
                return ["status": 200, "retryAfter": NSNull(), "body": ""]
            },
            sleep: { _ in try await Task.sleep(for: .seconds(60)) }
        )
        do {
            _ = try await client.postJSON(
                path: "/api/x",
                bodyJSON: "{}",
                mayDispatch: { throw CancellationError() },
                in: WKWebView(frame: .zero)
            )
            XCTFail("expected the veto to throw")
        } catch is CancellationError {}
        XCTAssertEqual(evaluations, 0, "a vetoed POST never reaches the page")
    }

    @MainActor
    func testAllEntryPointsAreBounded() async {
        // Same hung evaluator + immediate sleep: every JS-evaluating entry
        // point must produce .timedOut, proving none bypasses `bounded`.
        func hungClient() -> WebUsageClient {
            WebUsageClient(
                evaluator: { _, _, _ in
                    await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }
                    return nil
                },
                sleep: { _ in }
            )
        }
        let webView = WKWebView(frame: .zero)
        func expectTimeout(
            _ name: String,
            _ operation: () async throws -> Void
        ) async {
            do {
                try await operation()
                XCTFail("\(name): expected timedOut")
            } catch let error as WebUsageClientError {
                XCTAssertEqual(error, .timedOut, name)
            } catch {
                XCTFail("\(name): expected timedOut, got \(error)")
            }
        }
        await expectTimeout("fetch") {
            _ = try await hungClient().fetch(path: "/x", expectedOrigin: "https://claude.ai", in: webView)
        }
        await expectTimeout("fetchChatGPT") {
            _ = try await hungClient().fetchChatGPT(in: webView)
        }
        await expectTimeout("fetchCursor") {
            _ = try await hungClient().fetchCursor(in: webView)
        }
        await expectTimeout("postJSON") {
            _ = try await hungClient().postJSON(path: "/x", bodyJSON: "{}", in: webView)
        }
        await expectTimeout("resourcePaths") {
            _ = try await hungClient().resourcePaths(expectedOrigin: "https://claude.ai", in: webView)
        }
    }
}
