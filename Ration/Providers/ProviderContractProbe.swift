import Foundation
import WebKit

@MainActor
struct ProviderContractProbeRuntime {
    let isEnabled: Bool
    let fileURL: URL
    let recorder: ProviderContractRecorder?
    let adapters: [any ProviderAdapter]
    let startupError: String?

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        fileURL = temporaryDirectory
            .appending(path: "ration-provider-contracts.json")
        // The capture probe swizzles fetch/XHR on the provider pages. It is a
        // development-only diagnostic, so it is compiled in for DEBUG/test
        // builds only and can never activate in a shipped release build.
        #if DEBUG
        isEnabled = arguments.contains("--capture-provider-contracts")
        #else
        isEnabled = false
        #endif

        if isEnabled {
            do {
                if FileManager.default.fileExists(atPath: fileURL.path) {
                    try FileManager.default.removeItem(at: fileURL)
                }
                startupError = nil
            } catch {
                startupError = "Could not clear the provider capture file: \(error.localizedDescription)"
            }
            recorder = ProviderContractRecorder(fileURL: fileURL)
            adapters = Provider.allCases.map {
                ProviderContractProbeAdapter(provider: $0)
            }
        } else {
            startupError = nil
            recorder = nil
            adapters = []
        }
    }
}

@MainActor
struct ProviderContractProbeAdapter: ProviderAdapter {
    let provider: Provider

    var signInURL: URL {
        switch provider {
        case .claude:
            URL(string: "https://claude.ai/settings/usage")!
        case .chatGPT:
            URL(string: "https://chatgpt.com/codex/settings/usage")!
        case .cursor:
            URL(string: "https://cursor.com/dashboard")!
        }
    }

    func verifySession(in webView: WKWebView) async throws {
        throw ProviderError.integrationChanged
    }

    func fetchUsage(
        accountID: UUID,
        in webView: WKWebView
    ) async throws -> UsageSnapshot {
        throw ProviderError.integrationChanged
    }
}

indirect enum ProviderContractShape: Codable, Equatable, Hashable, Sendable {
    case null
    case boolean
    case number
    case string
    case unknown
    case array(ProviderContractShape)
    case object([String: ProviderContractShape])

    fileprivate static func parse(_ value: Any, depth: Int = 0) -> Self? {
        guard depth <= 8 else { return .unknown }

        if let scalar = value as? String {
            return switch scalar {
            case "null": .null
            case "boolean": .boolean
            case "number": .number
            case "string": .string
            case "unknown": .unknown
            default: nil
            }
        }

        guard
            let node = value as? [String: Any],
            node.count == 1
        else {
            return nil
        }

        if let element = node["array"] {
            guard let parsed = parse(element, depth: depth + 1) else {
                return nil
            }
            return .array(parsed)
        }

        if let rawFields = node["object"] as? [String: Any] {
            guard rawFields.count <= 100 else { return nil }
            var fields: [String: ProviderContractShape] = [:]
            for (rawName, rawShape) in rawFields {
                guard let shape = parse(rawShape, depth: depth + 1) else {
                    return nil
                }
                fields[ProviderContractSanitizer.fieldName(rawName)] = shape
            }
            return .object(fields)
        }

        return nil
    }
}

struct ProviderContractCapture: Codable, Equatable, Hashable, Sendable {
    let provider: Provider
    let method: String
    let path: String
    let status: Int
    let shape: ProviderContractShape
    // The request body's key-shape (names + types, never values). Present for
    // POST/PUT/PATCH requests so the send contract can be discovered; `.null`
    // for requests without a JSON body.
    let requestShape: ProviderContractShape
    /// Cross-origin captures only: the sanitized target origin (candidate set
    /// or `:redacted`). Nil for same-origin requests.
    let targetOrigin: String?
    /// PRESENCE booleans only — Phase 0 gate 2. The capture can answer
    /// "was an Authorization header sent" and "were cookies included", never
    /// what any header contained. There is deliberately no field a header
    /// VALUE could travel through.
    let hasAuthorizationHeader: Bool
    let usedCredentialsInclude: Bool

    init?(messageBody: Any, originHost: String) {
        guard
            let provider = ProviderContractSanitizer.provider(for: originHost),
            let body = messageBody as? [String: Any],
            Set(body.keys) == Set([
                "method", "path", "status", "shape", "requestShape",
                "targetOrigin", "hasAuthorizationHeader", "usedCredentialsInclude",
            ]),
            let rawMethod = body["method"] as? String,
            let method = ProviderContractSanitizer.method(rawMethod),
            let rawPath = body["path"] as? String,
            let path = ProviderContractSanitizer.path(rawPath),
            let status = ProviderContractSanitizer.status(body["status"]),
            let shape = ProviderContractShape.parse(body["shape"] as Any),
            let requestShape = ProviderContractShape.parse(body["requestShape"] as Any),
            let hasAuthorizationHeader = body["hasAuthorizationHeader"] as? Bool,
            let usedCredentialsInclude = body["usedCredentialsInclude"] as? Bool
        else {
            return nil
        }

        self.provider = provider
        self.method = method
        self.path = path
        self.status = status
        self.shape = shape
        self.requestShape = requestShape
        self.targetOrigin = ProviderContractSanitizer.targetOrigin(body["targetOrigin"] as? String)
        self.hasAuthorizationHeader = hasAuthorizationHeader
        self.usedCredentialsInclude = usedCredentialsInclude
    }
}

private enum ProviderContractSanitizer {
    private static let allowedMethods = Set([
        "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"
    ])
    private static let allowedPathSegments = Set([
        "account", "accounts", "api", "backend-api", "billing", "chat",
        "chat_conversations", "codex", "completion", "conversations", "limits",
        "messages", "organizations", "plans", "rate-limits", "retry_completion",
        "subscription", "subscriptions", "usage", "v1", "v2", "v3", "wham",
        // Cursor, live-verified (see field-name note below). The
        // `aiserver.v1.dashboardservice`/`getcurrentperiodusage` segments were
        // dropped with the cancelled cross-origin api2.cursor.sh primitive —
        // everything this app reads is same-origin cursor.com.
        // NOTE: this set is duplicated in `ProviderContractProbeScript.source`
        // below; keep the two in sync (deriving one from the other is a
        // worthwhile follow-up, out of scope for this branch).
        "auth", "stripe", "dashboard", "get-monthly-invoice",
        "get-filtered-usage-events", "get-hard-limit"
    ])
    private static let allowedFieldNames = Set([
        "active", "allowed", "attachments", "cap", "capabilities", "content", "conversation_uuid",
        "count", "current", "current_leaf_message_uuid", "daily", "data",
        "days", "end", "ends_at", "error", "files", "five_hour", "hours", "interval",
        "limit", "limit_reached", "limit_window_seconds", "limits", "max",
        "message", "minutes", "model", "monthly", "name", "next",
        "parent_message_uuid", "percent", "percentage",
        // Cursor, LIVE-VERIFIED 2026-07-28 against a real authenticated account
        // (docs/provider-contracts/cursor.md). The earlier `totalPercentUsed`/
        // `apiPercentUsed` guesses were DISPROVEN — cursor.com exposes no
        // percentage at all — so they are dropped rather than left implying they
        // might still show up:
        "membershipType", "individualMembershipType", "isYearlyPlan",
        "subscriptionStatus", "startOfMonth", "pricingDescription",
        "periodStartMs", "periodEndMs",
        "totalUsageEventsCount", "usageEventsDisplay",
        "isChargeable", "chargedCents", "isTokenBasedCall",
        "requestsCosts", "usageBasedCosts", "tokenUsage", "noUsageBasedAllowed",
        "personalized_styles", "plan", "plan_type", "primary", "primary_window",
        "prompt", "rate_limit",
        "rate_limits", "remaining", "rendering_mode", "reset", "reset_after_seconds",
        "reset_at", "reset_time",
        "resets_at", "rolling", "secondary", "seconds", "seven_day", "start",
        "secondary_window", "starts_at", "status", "subscription", "sync_sources",
        "text", "timestamp", "timezone", "tools",
        "total", "type", "uuid",
        "usage", "used", "used_percent", "utilization", "value", "weekly",
        "weekly_limit", "window", "window_duration_mins", "window_minutes", "windows"
    ])

    static func provider(for host: String) -> Provider? {
        if Provider.claude.matchesAppHost(host) {
            return .claude
        }
        if Provider.chatGPT.matchesAppHost(host) {
            return .chatGPT
        }
        if Provider.cursor.matchesAppHost(host) {
            return .cursor
        }
        return nil
    }

    /// Cross-origin hosts the probe may capture FROM a provider page — an
    /// explicit compile-time candidate set (Phase 0 gate 2); everything else
    /// stays dropped exactly as before. Cursor's dashboard is believed (from
    /// community tooling — unverified until the probe run) to fetch its usage
    /// numbers from `api2.cursor.sh` rather than the page origin.
    static let candidateCrossOriginHosts: Set<String> = ["api2.cursor.sh"]

    /// Sanitized target origin for a capture: nil for same-origin requests,
    /// the exact origin for a candidate host, `:redacted` otherwise (the JS
    /// drops non-candidates already; this is defense-in-depth if that guard
    /// is ever bypassed).
    static func targetOrigin(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let url = URL(string: raw), let host = url.host()?.lowercased(),
              candidateCrossOriginHosts.contains(host), url.scheme == "https" else {
            return ":redacted"
        }
        return "https://\(host)"
    }

    static func method(_ rawMethod: String) -> String? {
        let method = rawMethod.uppercased()
        return allowedMethods.contains(method) ? method : nil
    }

    static func status(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let status = number.intValue
        return (100...599).contains(status) ? status : nil
    }

    static func path(_ rawPath: String) -> String? {
        guard !rawPath.isEmpty, rawPath.utf8.count <= 1_024 else { return nil }
        let withoutQuery = rawPath.split(separator: "?", maxSplits: 1)[0]
            .split(separator: "#", maxSplits: 1)[0]
        guard withoutQuery.first == "/" else { return nil }

        let segments = withoutQuery.split(separator: "/", omittingEmptySubsequences: true)
        let sanitized = segments.map { segment -> String in
            let decoded = String(segment).removingPercentEncoding ?? String(segment)
            let normalized = decoded.lowercased()
            return allowedPathSegments.contains(normalized) ? normalized : ":redacted"
        }
        return "/" + sanitized.joined(separator: "/")
    }

    static func fieldName(_ rawName: String) -> String {
        allowedFieldNames.contains(rawName) ? rawName : ":redacted"
    }
}

actor ProviderContractRecorder {
    private let fileURL: URL
    private var captures: Set<ProviderContractCapture> = []

    init(fileURL: URL) {
        self.fileURL = fileURL
    }

    func record(_ capture: ProviderContractCapture) throws {
        guard !captures.contains(capture) else { return }
        var updatedCaptures = captures
        updatedCaptures.insert(capture)

        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(
            updatedCaptures.sorted {
                ($0.provider.rawValue, $0.path, $0.method, $0.status)
                    < ($1.provider.rawValue, $1.path, $1.method, $1.status)
            }
        )
        try data.write(to: fileURL, options: .atomic)
        captures = updatedCaptures
    }
}

enum ProviderContractProbeScript {
    static let messageHandlerName = "providerContractProbe"

    static let source = #"""
    (() => {
      if (window.__rationContractProbeInstalled) return;
      window.__rationContractProbeInstalled = true;

      const handler = window.webkit?.messageHandlers?.providerContractProbe;
      if (!handler) return;

      const allowedPathSegments = new Set([
        "account", "accounts", "api", "backend-api", "billing", "chat",
        "chat_conversations", "codex", "completion", "conversations", "limits",
        "messages", "organizations", "plans", "rate-limits", "retry_completion",
        "subscription", "subscriptions", "usage", "v1", "v2", "v3", "wham",
        // Cursor, live-verified 2026-07-28 (docs/provider-contracts/cursor.md).
        // Without these the dashboard paths the adapter actually reads would be
        // redacted here, making a probe run unable to corroborate the contract.
        "auth", "stripe", "dashboard", "get-monthly-invoice",
        "get-filtered-usage-events", "get-hard-limit"
      ]);
      const allowedFieldNames = new Set([
        "active", "allowed", "attachments", "cap", "capabilities", "content", "conversation_uuid",
        "count", "current", "current_leaf_message_uuid", "daily", "data",
        "days", "end", "ends_at", "error", "files", "five_hour", "hours", "interval",
        "limit", "limit_reached", "limit_window_seconds", "limits", "max",
        "message", "minutes", "model", "monthly", "name", "next",
        "parent_message_uuid", "percent", "percentage",
        // Cursor, LIVE-VERIFIED 2026-07-28 against a real authenticated account
        // (docs/provider-contracts/cursor.md). The earlier `totalPercentUsed`/
        // `apiPercentUsed` guesses were DISPROVEN — cursor.com exposes no
        // percentage at all — so they are dropped rather than left implying they
        // might still show up:
        "membershipType", "individualMembershipType", "isYearlyPlan",
        "subscriptionStatus", "startOfMonth", "pricingDescription",
        "periodStartMs", "periodEndMs",
        "totalUsageEventsCount", "usageEventsDisplay",
        "isChargeable", "chargedCents", "isTokenBasedCall",
        "requestsCosts", "usageBasedCosts", "tokenUsage", "noUsageBasedAllowed",
        "personalized_styles", "plan", "plan_type", "primary", "primary_window",
        "prompt", "rate_limit",
        "rate_limits", "remaining", "rendering_mode", "reset", "reset_after_seconds",
        "reset_at", "reset_time",
        "resets_at", "rolling", "secondary", "seconds", "seven_day", "start",
        "secondary_window", "starts_at", "status", "subscription", "sync_sources",
        "text", "timestamp", "timezone", "tools",
        "total", "type", "uuid",
        "usage", "used", "used_percent", "utilization", "value", "weekly",
        "weekly_limit", "window", "window_duration_mins", "window_minutes", "windows"
      ]);

      const sanitizePath = pathname => "/" + pathname
        .split("/")
        .filter(Boolean)
        .map(segment => {
          try {
            const normalized = decodeURIComponent(segment).toLowerCase();
            return allowedPathSegments.has(normalized) ? normalized : ":redacted";
          } catch {
            return ":redacted";
          }
        })
        .join("/");

      const describe = (value, depth = 0) => {
        if (depth > 8) return "unknown";
        if (value === null) return "null";
        if (Array.isArray(value)) {
          return { array: value.length ? describe(value[0], depth + 1) : "unknown" };
        }
        if (typeof value === "object") {
          const fields = {};
          for (const [key, child] of Object.entries(value).slice(0, 100)) {
            const safeKey = allowedFieldNames.has(key) ? key : ":redacted";
            fields[safeKey] = describe(child, depth + 1);
          }
          return { object: fields };
        }
        if (typeof value === "boolean") return "boolean";
        if (typeof value === "number") return "number";
        if (typeof value === "string") return "string";
        return "unknown";
      };

      const describeBody = requestBody => {
        if (typeof requestBody !== "string" || requestBody.length === 0) return "null";
        try {
          return describe(JSON.parse(requestBody));
        } catch {
          return "unknown";
        }
      };

      // Cross-origin capture is restricted to an explicit candidate set
      // (Phase 0 gate 2) — everything else stays dropped. Only presence
      // BOOLEANS about authentication ever leave the page; no header value
      // has a field to travel through.
      const candidateCrossOriginHosts = new Set(["api2.cursor.sh"]);

      const post = (urlValue, method, status, payload, requestBody, hasAuthorizationHeader, usedCredentialsInclude) => {
        try {
          const url = new URL(urlValue, location.href);
          const crossOrigin = url.origin !== location.origin;
          if (crossOrigin && !candidateCrossOriginHosts.has(url.host)) return;
          handler.postMessage({
            method: String(method || "GET").toUpperCase(),
            path: sanitizePath(url.pathname),
            status,
            shape: describe(payload),
            requestShape: describeBody(requestBody),
            targetOrigin: crossOrigin ? url.origin : "",
            hasAuthorizationHeader: hasAuthorizationHeader === true,
            usedCredentialsInclude: usedCredentialsInclude === true
          });
        } catch {}
      };

      // Record JSON responses (the usage read) and every mutation (POST/PUT/…),
      // even when the response is not JSON — the message-send request streams SSE,
      // so its request shape must be captured without a JSON response body.
      const inspectResponse = async (response, method, requestBody, hasAuth, credsInclude) => {
        let payload = null;
        let isJson = false;
        try {
          payload = await response.clone().json();
          isJson = true;
        } catch {
          payload = null;
        }
        const isMutation = String(method || "GET").toUpperCase() !== "GET";
        if (isJson || isMutation) {
          post(response.url, method, response.status, payload, requestBody, hasAuth, credsInclude);
        }
      };

      // Auth PRESENCE over the EFFECTIVE request, per the Fetch standard's
      // precedence: `init` members override `Request`-carried ones, and an
      // `init.headers` REPLACES the Request's header list wholesale. Only the
      // header NAME is matched; the value is never read.
      const effectiveHasAuthHeader = (input, init) => {
        try {
          if (init && init.headers !== undefined) {
            return new Headers(init.headers).has("authorization");
          }
          if (input instanceof Request) {
            return input.headers.has("authorization");
          }
          return false;
        } catch { return false; }
      };
      const effectiveCredentialsInclude = (input, init) => {
        try {
          const mode = (init && init.credentials !== undefined)
            ? init.credentials
            : (input instanceof Request ? input.credentials : undefined);
          return mode === "include";
        } catch { return false; }
      };

      const originalFetch = window.fetch;
      window.fetch = async function(input, init) {
        const response = await originalFetch.apply(this, arguments);
        const method = init?.method || (input instanceof Request ? input.method : "GET");
        const requestBody = typeof init?.body === "string" ? init.body : null;
        const hasAuth = effectiveHasAuthHeader(input, init);
        const credsInclude = effectiveCredentialsInclude(input, init);
        void inspectResponse(response, method, requestBody, hasAuth, credsInclude);
        return response;
      };

      const originalOpen = XMLHttpRequest.prototype.open;
      const originalSend = XMLHttpRequest.prototype.send;
      const originalSetRequestHeader = XMLHttpRequest.prototype.setRequestHeader;
      XMLHttpRequest.prototype.open = function(method, url) {
        this.__rationProbeMethod = method;
        this.__rationProbeURL = url;
        this.__rationProbeHasAuth = false;
        return originalOpen.apply(this, arguments);
      };
      XMLHttpRequest.prototype.setRequestHeader = function(name) {
        // Name only — the value argument is deliberately never touched.
        if (String(name).toLowerCase() === "authorization") {
          this.__rationProbeHasAuth = true;
        }
        return originalSetRequestHeader.apply(this, arguments);
      };
      XMLHttpRequest.prototype.send = function(body) {
        const requestBody = typeof body === "string" ? body : null;
        this.addEventListener("load", () => {
          let payload = null;
          let isJson = false;
          try {
            payload = this.responseType === "json"
              ? this.response
              : JSON.parse(this.responseText);
            isJson = true;
          } catch {
            payload = null;
          }
          const isMutation =
            String(this.__rationProbeMethod || "GET").toUpperCase() !== "GET";
          if (isJson || isMutation) {
            post(
              this.responseURL || this.__rationProbeURL,
              this.__rationProbeMethod,
              this.status,
              payload,
              requestBody,
              this.__rationProbeHasAuth === true,
              this.withCredentials === true
            );
          }
        }, { once: true });
        return originalSend.apply(this, arguments);
      };
    })();
    """#
}

@MainActor
final class ProviderContractProbeMessageHandler: NSObject, WKScriptMessageHandler {
    private let recorder: ProviderContractRecorder
    private let onRecordingError: (String) -> Void

    init(
        recorder: ProviderContractRecorder,
        onRecordingError: @escaping (String) -> Void
    ) {
        self.recorder = recorder
        self.onRecordingError = onRecordingError
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard let capture = ProviderContractCapture(
            messageBody: message.body,
            originHost: message.frameInfo.securityOrigin.host
        ) else {
            return
        }

        Task {
            do {
                try await recorder.record(capture)
            } catch {
                onRecordingError(
                    "Provider contract capture failed: \(error.localizedDescription)"
                )
            }
        }
    }
}
