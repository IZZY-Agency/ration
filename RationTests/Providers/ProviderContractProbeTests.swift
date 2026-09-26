import Foundation
import XCTest
@testable import Ration

final class ProviderContractProbeTests: XCTestCase {
    @MainActor
    func testProbeAdaptersOpenProviderOwnedEntryPages() {
        let claude = ProviderContractProbeAdapter(provider: .claude)
        let chatGPT = ProviderContractProbeAdapter(provider: .chatGPT)

        XCTAssertEqual(
            claude.signInURL.absoluteString,
            "https://claude.ai/settings/usage"
        )
        XCTAssertEqual(
            chatGPT.signInURL.absoluteString,
            "https://chatgpt.com/codex/settings/usage"
        )
        XCTAssertEqual(
            ProviderContractProbeAdapter(provider: .cursor).signInURL.absoluteString,
            "https://cursor.com/dashboard"
        )
    }

    @MainActor
    func testProbeRuntimeRequiresExplicitCaptureFlag() {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)

        let normal = ProviderContractProbeRuntime(
            arguments: [],
            temporaryDirectory: directory
        )
        let capture = ProviderContractProbeRuntime(
            arguments: ["--capture-provider-contracts"],
            temporaryDirectory: directory
        )

        XCTAssertFalse(normal.isEnabled)
        XCTAssertTrue(normal.adapters.isEmpty)
        XCTAssertNil(normal.recorder)
        XCTAssertTrue(capture.isEnabled)
        XCTAssertEqual(capture.adapters.map(\.provider), Provider.allCases)
        XCTAssertNotNil(capture.recorder)
        XCTAssertEqual(
            capture.fileURL,
            directory.appending(path: "ration-provider-contracts.json")
        )
    }

    func testCaptureSanitizesPathAndDynamicFieldNames() throws {
        let capture = try XCTUnwrap(
            ProviderContractCapture(
                messageBody: [
                    "method": "GET",
                    "path": "/api/organizations/123e4567-e89b-12d3-a456-426614174000/usage?email=private@example.com",
                    "status": 200,
                    "shape": [
                        "object": [
                            "five_hour": "number",
                            "private@example.com": "string"
                        ]
                    ],
                    "requestShape": "null",
                    "targetOrigin": "",
                    "hasAuthorizationHeader": false,
                    "usedCredentialsInclude": false
                ],
                originHost: "claude.ai"
            )
        )

        XCTAssertEqual(capture.provider, .claude)
        XCTAssertEqual(capture.path, "/api/organizations/:redacted/usage")
        XCTAssertEqual(
            capture.shape,
            .object([
                ":redacted": .string,
                "five_hour": .number
            ])
        )
    }

    func testCaptureRedactsShortPersonalPathSegmentsAndUnknownObjectKeys() throws {
        let capture = try XCTUnwrap(
            ProviderContractCapture(
                messageBody: [
                    "method": "GET",
                    "path": "/api/organizations/acme/usage",
                    "status": 200,
                    "shape": [
                        "object": [
                            "personal_handle": "string",
                            "resets_at": "string"
                        ]
                    ],
                    "requestShape": "null",
                    "targetOrigin": "",
                    "hasAuthorizationHeader": false,
                    "usedCredentialsInclude": false
                ],
                originHost: "claude.ai"
            )
        )

        XCTAssertEqual(capture.path, "/api/organizations/:redacted/usage")
        XCTAssertEqual(
            capture.shape,
            .object([
                ":redacted": .string,
                "resets_at": .string
            ])
        )
    }

    func testCapturePreservesKnownSafeCodexUsageContractTerms() throws {
        let capture = try XCTUnwrap(
            ProviderContractCapture(
                messageBody: [
                    "method": "GET",
                    "path": "/api/codex/usage",
                    "status": 200,
                    "shape": [
                        "object": [
                            "primary_window": [
                                "object": [
                                    "limit_window_seconds": "number",
                                    "reset_after_seconds": "number",
                                    "reset_at": "number",
                                    "used_percent": "number"
                                ]
                            ],
                            "secondary_window": "null",
                            "used_percent": "number",
                            "window_minutes": "number",
                            "window_duration_mins": "number",
                            "plan_type": "string"
                        ]
                    ],
                    "requestShape": "null",
                    "targetOrigin": "",
                    "hasAuthorizationHeader": false,
                    "usedCredentialsInclude": false
                ],
                originHost: "chatgpt.com"
            )
        )

        XCTAssertEqual(capture.path, "/api/codex/usage")
        XCTAssertEqual(
            capture.shape,
            .object([
                "primary_window": .object([
                    "limit_window_seconds": .number,
                    "reset_after_seconds": .number,
                    "reset_at": .number,
                    "used_percent": .number
                ]),
                "secondary_window": .null,
                "used_percent": .number,
                "window_minutes": .number,
                "window_duration_mins": .number,
                "plan_type": .string
            ])
        )
    }

    func testCaptureRecordsSendRequestBodyShapeWithRedactedValues() throws {
        // A message-send POST: the streaming completion carries no JSON response,
        // so the request body's key-shape is what discovers the contract. Known
        // keys survive; anything else (and every value) is redacted.
        let capture = try XCTUnwrap(
            ProviderContractCapture(
                messageBody: [
                    "method": "POST",
                    "path": "/api/organizations/123e4567-e89b-12d3-a456-426614174000/chat_conversations/abc/completion",
                    "status": 200,
                    "shape": "null",
                    "requestShape": [
                        "object": [
                            "prompt": "string",
                            "model": "string",
                            "parent_message_uuid": "string",
                            "attachments": ["array": "unknown"],
                            "super_secret_field": "string"
                        ]
                    ],
                    "targetOrigin": "",
                    "hasAuthorizationHeader": false,
                    "usedCredentialsInclude": false
                ],
                originHost: "claude.ai"
            )
        )

        XCTAssertEqual(capture.method, "POST")
        XCTAssertEqual(
            capture.path,
            "/api/organizations/:redacted/chat_conversations/:redacted/completion"
        )
        XCTAssertEqual(capture.shape, .null)
        XCTAssertEqual(
            capture.requestShape,
            .object([
                "prompt": .string,
                "model": .string,
                "parent_message_uuid": .string,
                "attachments": .array(.unknown),
                ":redacted": .string
            ])
        )
    }

    func testCaptureRejectsMessagesThatCouldContainSensitiveMaterial() {
        let forbiddenKeys = ["body", "headers", "cookies", "query"]

        for forbiddenKey in forbiddenKeys {
            let capture = ProviderContractCapture(
                messageBody: [
                    "method": "GET",
                    "path": "/api/usage",
                    "status": 200,
                    "shape": "string",
                    "requestShape": "null",
                    forbiddenKey: "must-not-cross-boundary"
                ],
                originHost: "claude.ai"
            )
            XCTAssertNil(capture, "Expected \(forbiddenKey) to be rejected")
        }
    }

    func testCaptureRejectsUntrustedHostsAndInvalidMethods() {
        let body: [String: Any] = [
            "method": "GET",
            "path": "/api/usage",
            "status": 200,
            "shape": "string",
            "requestShape": "null",
            "targetOrigin": "",
            "hasAuthorizationHeader": false,
            "usedCredentialsInclude": false
        ]

        XCTAssertNil(
            ProviderContractCapture(
                messageBody: body,
                originHost: "example.com"
            )
        )
        XCTAssertNil(
            ProviderContractCapture(
                messageBody: body.merging(["method": "TRACE"]) { _, new in new },
                originHost: "claude.ai"
            )
        )
    }

    /// Successor to the original "never mentions authorization" test: the
    /// probe now legitimately matches the Authorization header NAME (Phase 0
    /// gate 2 — presence booleans), so the protected property is restated as
    /// names-only matching with no route for a VALUE to leave the page.
    func testProbeScriptMatchesHeaderNamesOnlyAndReadsNoValues() {
        let source = ProviderContractProbeScript.source.lowercased()

        XCTAssertTrue(source.contains("response.clone()"))
        XCTAssertTrue(source.contains(".pathname"))
        XCTAssertTrue(source.contains(":redacted"))
        XCTAssertFalse(source.contains("path: url.pathname"))
        XCTAssertFalse(source.contains("document.cookie"))
        XCTAssertFalse(source.contains("console."))
        // Presence checks are allowed; VALUE reads are not.
        XCTAssertTrue(source.contains(#"has("authorization")"#))
        XCTAssertFalse(source.contains(#"get("authorization")"#), "must never read the header value")
        XCTAssertFalse(source.contains("getresponseheader"))
        XCTAssertFalse(source.contains("getallresponseheaders"))
        // The posted message carries booleans, never a header string.
        XCTAssertTrue(source.contains("hasauthorizationheader: hasauthorizationheader === true"))
    }

    /// The capture struct is the second line of defence: a message smuggling
    /// an extra field (e.g. a header value) is rejected wholesale by the
    /// exact key-set check.
    func testCaptureRejectsMessagesWithUnexpectedFields() {
        let body: [String: Any] = [
            "method": "GET", "path": "/api/usage", "status": 200,
            "shape": "string", "requestShape": "null",
            "targetOrigin": "", "hasAuthorizationHeader": false,
            "usedCredentialsInclude": false,
            "authorizationValue": "Bearer sk-leak",
        ]
        XCTAssertNil(ProviderContractCapture(messageBody: body, originHost: "cursor.com"))
    }

    func testCursorCaptureCarriesSanitizedTargetOriginAndAuthPresence() throws {
        // Subject: the SANITIZER (targetOrigin retention, auth-presence flags,
        // path-segment and field allowlisting) — not the shipped fetch path.
        // The payload uses the LIVE-VERIFIED same-origin contract
        // (`get-monthly-invoice` → `periodEndMs`, 2026-07-28); the earlier
        // api2.cursor.sh / `totalPercentUsed` shape was disproven and removed
        // from the allowlists. `targetOrigin` still exercises the cross-origin
        // candidate branch, which the sanitizer retains even though the shipped
        // adapter is same-origin only.
        let capture = try XCTUnwrap(ProviderContractCapture(
            messageBody: [
                "method": "POST",
                "path": "/api/dashboard/Get-Monthly-Invoice",
                "status": 200,
                "shape": ["object": ["periodEndMs": "string", "secretField": "string"]],
                "requestShape": "null",
                "targetOrigin": "https://api2.cursor.sh",
                "hasAuthorizationHeader": true,
                "usedCredentialsInclude": false,
            ],
            originHost: "cursor.com"
        ))
        XCTAssertEqual(capture.provider, .cursor)
        XCTAssertEqual(capture.targetOrigin, "https://api2.cursor.sh")
        XCTAssertTrue(capture.hasAuthorizationHeader)
        XCTAssertFalse(capture.usedCredentialsInclude)
        XCTAssertEqual(capture.path, "/api/dashboard/get-monthly-invoice")
        XCTAssertEqual(capture.shape, .object(["periodEndMs": .string, ":redacted": .string]))
    }

    func testDisprovenCursorPercentageFieldsAreNoLongerAllowlisted() throws {
        // Guard against the disproven percentage-pool names creeping back in:
        // cursor.com exposes no percentage, so a payload carrying them must be
        // redacted rather than recorded as if it were contract evidence.
        let capture = try XCTUnwrap(ProviderContractCapture(
            messageBody: [
                "method": "GET", "path": "/api/usage", "status": 200,
                "shape": ["object": ["totalPercentUsed": "number", "apiPercentUsed": "number"]],
                "requestShape": "null",
                "targetOrigin": "",
                "hasAuthorizationHeader": false,
                "usedCredentialsInclude": true,
            ],
            originHost: "cursor.com"
        ))
        XCTAssertEqual(capture.shape, .object([":redacted": .number]))
    }

    func testNonCandidateTargetOriginIsRedacted() throws {
        let capture = try XCTUnwrap(ProviderContractCapture(
            messageBody: [
                "method": "GET", "path": "/api/usage", "status": 200,
                "shape": "string", "requestShape": "null",
                "targetOrigin": "https://evil.example.com",
                "hasAuthorizationHeader": false,
                "usedCredentialsInclude": true,
            ],
            originHost: "cursor.com"
        ))
        XCTAssertEqual(capture.targetOrigin, ":redacted")
    }

    func testSameOriginCaptureHasNilTargetOrigin() throws {
        let capture = try XCTUnwrap(ProviderContractCapture(
            messageBody: [
                "method": "GET", "path": "/api/usage", "status": 200,
                "shape": "string", "requestShape": "null",
                "targetOrigin": "",
                "hasAuthorizationHeader": false,
                "usedCredentialsInclude": true,
            ],
            originHost: "cursor.com"
        ))
        XCTAssertNil(capture.targetOrigin)
    }

    /// The JS-level gate: cross-origin capture is allowed ONLY for the
    /// compile-time candidate set.
    func testProbeScriptRestrictsCrossOriginToCandidateHosts() throws {
        let source = ProviderContractProbeScript.source
        XCTAssertEqual(
            try scriptSet(named: "candidateCrossOriginHosts", in: source),
            ["api2.cursor.sh"]
        )
        XCTAssertTrue(source.contains("if (crossOrigin && !candidateCrossOriginHosts.has(url.host)) return;"))
    }

    /// The JS allowlists are derived from the Swift ones: the script
    /// must carry EXACTLY the Swift sets — nothing missing, nothing extra —
    /// so the page-side and the Swift-side sanitizers can never drift again.
    func testProbeScriptAllowlistsAreExactlyTheSwiftSets() throws {
        let source = ProviderContractProbeScript.source
        XCTAssertEqual(
            try scriptSet(named: "allowedPathSegments", in: source),
            ProviderContractAllowlist.pathSegments
        )
        XCTAssertEqual(
            try scriptSet(named: "allowedFieldNames", in: source),
            ProviderContractAllowlist.fieldNames
        )
        XCTAssertEqual(
            try scriptSet(named: "candidateCrossOriginHosts", in: source),
            ProviderContractAllowlist.candidateCrossOriginHosts
        )
        XCTAssertFalse(source.contains("__RATION_"), "every placeholder must be substituted")
    }

    /// Decodes the JSON array literal in `const <name> = new Set(<array>);`.
    private func scriptSet(named name: String, in source: String) throws -> Set<String> {
        let opener = "const \(name) = new Set("
        let start = try XCTUnwrap(source.range(of: opener), "no Set named \(name)")
        let rest = source[start.upperBound...]
        let end = try XCTUnwrap(rest.range(of: ");"), "unterminated Set \(name)")
        let literal = String(rest[..<end.lowerBound])
        let values = try JSONDecoder().decode([String].self, from: Data(literal.utf8))
        XCTAssertEqual(values.count, Set(values).count, "\(name) has duplicates")
        return Set(values)
    }

    @MainActor
    func testProfileManagerInstallsProbeOnlyWhenExplicitlyConfigured() {
        let fileURL = FileManager.default.temporaryDirectory
            .appending(path: "contract-probe-\(UUID().uuidString).json")
        let recorder = ProviderContractRecorder(fileURL: fileURL)

        let normalWebView = WebProfileManager().makeWebView(profileID: UUID())
        let probeWebView = WebProfileManager(contractRecorder: recorder)
            .makeWebView(profileID: UUID())

        XCTAssertTrue(
            normalWebView.configuration.userContentController.userScripts.isEmpty
        )
        XCTAssertEqual(
            probeWebView.configuration.userContentController.userScripts.count,
            1
        )
        XCTAssertTrue(normalWebView.configuration.websiteDataStore.isPersistent)
        XCTAssertFalse(probeWebView.configuration.websiteDataStore.isPersistent)
    }


    @MainActor
    func testCaptureRuntimeClearsStaleOutputAtSessionStart() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let fileURL = directory
            .appending(path: "ration-provider-contracts.json")
        try Data("stale".utf8).write(to: fileURL)

        let runtime = ProviderContractProbeRuntime(
            arguments: ["--capture-provider-contracts"],
            temporaryDirectory: directory
        )

        XCTAssertTrue(runtime.isEnabled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
        XCTAssertNil(runtime.startupError)
    }

    func testRecorderWritesSanitizedDeduplicatedCaptures() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "captures.json")
        let recorder = ProviderContractRecorder(fileURL: fileURL)
        let capture = try XCTUnwrap(
            ProviderContractCapture(
                messageBody: [
                    "method": "GET",
                    "path": "/backend-api/organizations/a-very-long-private-identifier/usage?secret=value",
                    "status": 200,
                    "shape": ["object": ["seven_day": "number"]],
                    "requestShape": "null",
                    "targetOrigin": "",
                    "hasAuthorizationHeader": false,
                    "usedCredentialsInclude": false
                ],
                originHost: "chatgpt.com"
            )
        )

        try await recorder.record(capture)
        try await recorder.record(capture)

        let data = try Data(contentsOf: fileURL)
        let decoded = try JSONDecoder().decode(
            [ProviderContractCapture].self,
            from: data
        )
        let serialized = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertEqual(decoded, [capture])
        XCTAssertFalse(serialized.contains("private"))
        XCTAssertFalse(serialized.contains("secret"))
        XCTAssertFalse(serialized.contains("value"))
    }
}
