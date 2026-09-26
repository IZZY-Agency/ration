import Foundation
import WebKit

struct WebResponseEnvelope: Equatable, Sendable {
    let status: Int
    let retryAfter: String?
    let body: String
    /// The `type` of an error event found at the head of a 2xx SSE completion
    /// stream (`postCompletion` only), already sanitized. Never the body.
    var streamErrorType: WarmUpOutcome.StreamErrorKind? = nil
}

/// `wham/usage` plus the optional reset-credit read from the same evaluation.
struct ChatGPTFetchResult: Equatable, Sendable {
    let usage: WebResponseEnvelope
    /// nil = not read (non-2xx usage, abort, oversized, or wrong shape).
    let resetCredits: WebResponseEnvelope?
}

enum WebUsageClientError: Error, Equatable {
    case invalidResponse
    /// A bridge evaluation outlived `WebUsageClient.evaluationTimeout`. The
    /// hung `callAsyncJavaScript` task is abandoned (it ignores
    /// cancellation); `AccountSessionManager` recycles the web view on this
    /// error (unless an open sign-in session protects the profile). The
    /// recycle's `about:blank` navigation — NOT `stopLoading()`, which does
    /// not settle a pending callback — tears down the frame and is what
    /// eventually, best-effort, completes and releases the abandoned call.
    case timedOut
}

@MainActor
final class WebUsageClient {
    typealias Evaluator = @MainActor (
        _ script: String,
        _ arguments: [String: Any],
        _ webView: WKWebView
    ) async throws -> Any?

    /// Hard bound on ANY single JS-bridge evaluation. A page that never
    /// resolves the injected promise (interstitial/challenge, wedged
    /// WebContent process — issue ) otherwise hangs the account forever.
    static let evaluationTimeout: Duration = .seconds(60)

    typealias Sleep = @MainActor (Duration) async throws -> Void

    private let evaluator: Evaluator
    private let sleep: Sleep

    init(
        evaluator: @escaping Evaluator = WebUsageClient.liveEvaluator,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.evaluator = evaluator
        self.sleep = sleep
    }

    /// Races the evaluation against the timeout using two UNSTRUCTURED tasks
    /// and a once-guarded continuation. Deliberately NOT a task group: a
    /// hung `callAsyncJavaScript` ignores cancellation, and a group awaits
    /// all children — it would recreate the very hang this bounds. The
    /// losing task is abandoned; a MainActor once-guard discards its late
    /// result. (The abandoned task retains the web view until the recycle's
    /// `about:blank` navigation tears down the frame and — best-effort —
    /// settles the call; a bare `stopLoading()` does NOT settle a pending
    /// script callback, only frame destruction does.)
    ///
    /// The result is stored on the `@MainActor`-isolated `Race` rather than
    /// resumed through the continuation, so the non-`Sendable` `Any?`
    /// payload never has to cross the continuation boundary — the
    /// main-actor confinement is enforced by the compiler (the closures
    /// below can only touch `race.result` because `Race` is `@MainActor`),
    /// not by an `@unchecked Sendable` escape hatch.
    ///
    /// `cancellable`: the caller's cancellation ends the wait at once with
    /// `CancellationError` (the abandoned evaluation is then reaped like a
    /// timed-out one — `AccountSessionManager` navigates its view to
    /// `about:blank`). Off for the usage reads, whose callers rely on the
    /// existing timeout-only contract.
    private func bounded(
        cancellable: Bool = false,
        _ operation: @escaping @MainActor () async throws -> Any?
    ) async throws -> Any? {
        let sleep = self.sleep
        @MainActor final class Race {
            var delivered = false
            var result: Result<Any?, any Error>?
            var continuation: CheckedContinuation<Void, Never>?

            func deliver(_ result: Result<Any?, any Error>) {
                guard !delivered else { return }
                delivered = true
                self.result = result
                continuation?.resume()
                continuation = nil
            }

            func attach(_ continuation: CheckedContinuation<Void, Never>) {
                if delivered {
                    continuation.resume()
                } else {
                    self.continuation = continuation
                }
            }
        }
        if cancellable {
            try Task.checkCancellation()
        }
        let race = Race()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                race.attach(continuation)
                Task { @MainActor in
                    do {
                        let value = try await operation()
                        race.deliver(.success(value))
                    } catch {
                        race.deliver(.failure(error))
                    }
                }
                Task { @MainActor in
                    try? await sleep(Self.evaluationTimeout)
                    race.deliver(.failure(WebUsageClientError.timedOut))
                }
            }
        } onCancel: {
            guard cancellable else { return }
            Task { @MainActor in
                race.deliver(.failure(CancellationError()))
            }
        }
        guard let result = race.result else { throw WebUsageClientError.timedOut }
        // The loser — typically the `evaluationTimeout`
        // sleep, still suspended when the operation wins — keeps `race` alive
        // for as long as it remains suspended, which would otherwise retain an
        // accepted response body (up to `maxResponseBytes`) for the rest of
        // that window. Clear it immediately once copied to a local so the
        // payload can be released the moment the winner is known.
        race.result = nil
        return try result.get()
    }

    /// Same-origin authenticated GET. `expectedOrigin` is enforced INSIDE the
    /// evaluated script (not just by the caller's page-readiness check) so a
    /// navigation that lands the web view on a foreign origin between the
    /// readiness check and this evaluation cannot issue a credentialed request
    /// to another site. Mirrors the guard already baked into `postScript` /
    /// `chatGPTFetchScript`.
    func fetch(
        path: String,
        expectedOrigin: String,
        in webView: WKWebView
    ) async throws -> WebResponseEnvelope {
        let result = try await bounded { [evaluator] in
            try await evaluator(
                Self.fetchScript,
                ["path": path, "expectedOrigin": expectedOrigin],
                webView
            )
        }

        return try Self.envelope(from: result)
    }

    func fetchChatGPT(in webView: WKWebView) async throws -> ChatGPTFetchResult {
        let result = try await bounded { [evaluator] in
            try await evaluator(Self.chatGPTFetchScript, [:], webView)
        }
        let usage = try Self.envelope(from: result)
        // Lenient on purpose: a bad side-channel value is "not read", never a
        // failed usage fetch.
        let resetCredits = (result as? [String: Any]).flatMap { try? Self.envelope(from: $0["resetCredits"]) }
        return ChatGPTFetchResult(usage: usage, resetCredits: resetCredits)
    }

    #if DEBUG
    static var chatGPTFetchScriptForTesting: String { chatGPTFetchScript }
    /// The Cursor script body, for running under a stubbed `fetch` in an
    /// `about:blank` web view (see `CursorFetchScriptTests`). Production always
    /// passes `expectedOrigin: cursorOrigin`, so the gate still refuses to run
    /// anywhere but cursor.com.
    static var cursorFetchScriptForTesting: String { cursorFetchScript }
    /// The history script body, run the same way (`CursorHistoryScriptTests`).
    static var cursorHistoryScriptForTesting: String { cursorHistoryScript }
    #endif

    /// The only origin `fetchCursor` lets its script run on. Passed in as
    /// `expectedOrigin` (like the other scripts) rather than inlined, so the
    /// body can be exercised off-origin by tests; the value is fixed here.
    static let cursorOrigin = "https://cursor.com"

    /// Same-origin `https://cursor.com` multi-fetch that collapses the Cursor
    /// dashboard's spend model (plan tier + billing-cycle boundary + per-event
    /// charged cents) into the compact payload `CursorProviderAdapter.parse`
    /// decodes. Origin-guarded and bounded exactly like `chatGPTFetchScript`.
    func fetchCursor(in webView: WKWebView) async throws -> WebResponseEnvelope {
        let result = try await bounded { [evaluator] in
            try await evaluator(
                Self.cursorFetchScript,
                ["expectedOrigin": Self.cursorOrigin],
                webView
            )
        }

        return try Self.envelope(from: result)
    }

    /// Pause between the history script's requests, so a backfill trickles
    /// rather than bursts (12 invoices + up to `cursorHistoryMaxPages` pages).
    static let cursorHistoryPauseMilliseconds = 150

    /// Past Cursor cycles (`cursorHistoryScript`): the invoice boundaries of
    /// `months` (0-indexed, newest first) and each one's summed chargeable
    /// events, in the compact payload `CursorProviderAdapter.parseHistory`
    /// decodes. Origin-guarded and bounded exactly like `fetchCursor`.
    ///
    /// Cancellable (see `bounded`), and `mayDispatch` runs at the last native
    /// moment before the script is handed to WebKit — throwing vetoes it (an
    /// open sign-in session on this profile, say).
    func fetchCursorHistory(
        months: [CursorInvoiceMonth],
        currentPeriodStart: Date,
        pauseMilliseconds: Int = WebUsageClient.cursorHistoryPauseMilliseconds,
        mayDispatch: (@MainActor () throws -> Void)? = nil,
        in webView: WKWebView
    ) async throws -> WebResponseEnvelope {
        var monthArguments: [[String: Int]] = []
        for month in months {
            monthArguments.append(["year": month.year, "month": month.month])
        }
        let arguments: [String: Any] = [
            "expectedOrigin": Self.cursorOrigin,
            "months": monthArguments,
            "currentPeriodStartMs": currentPeriodStart.timeIntervalSince1970 * 1000,
            "pauseMs": pauseMilliseconds
        ]
        let result = try await bounded(cancellable: true) { [evaluator] in
            try mayDispatch?()
            return try await evaluator(Self.cursorHistoryScript, arguments, webView)
        }
        return try Self.envelope(from: result)
    }

    /// Same-origin JSON POST used for the auto-start keep-alive send. The
    /// completion endpoint streams Server-Sent Events, so the body is cancelled
    /// immediately after the status line — only acceptance (2xx) matters.
    ///
    /// `mayDispatch` runs at the last native moment before the script is
    /// handed to WebKit (inside the bounded task, after any hop); throwing
    /// vetoes the request so it never reaches the page.
    func postJSON(
        path: String,
        bodyJSON: String,
        mayDispatch: (@MainActor () throws -> Void)? = nil,
        in webView: WKWebView
    ) async throws -> WebResponseEnvelope {
        let result = try await bounded { [evaluator] in
            try mayDispatch?()
            return try await evaluator(
                Self.postScript,
                ["path": path, "bodyJSON": bodyJSON],
                webView
            )
        }
        return try Self.envelope(from: result)
    }

    /// The Claude completion POST. Same as `postJSON`, except that on a 2xx it
    /// peeks at the head of the SSE stream (at most
    /// `streamPeekBytes` / `streamPeekMilliseconds`, stopping at the first
    /// error event or `message_stop`) for an error event, and reports only
    /// that event's `type`. The status, the dispatch, and the cancellation
    /// of the rest of the stream are unchanged; the body is never returned.
    func postCompletion(
        path: String,
        bodyJSON: String,
        mayDispatch: (@MainActor () throws -> Void)? = nil,
        in webView: WKWebView
    ) async throws -> WebResponseEnvelope {
        let result = try await bounded { [evaluator] in
            try mayDispatch?()
            return try await evaluator(
                Self.completionPostScript,
                ["path": path, "bodyJSON": bodyJSON],
                webView
            )
        }
        return try Self.envelope(from: result)
    }

    static let streamPeekBytes = 16_384
    static let streamPeekMilliseconds = 4_000

    /// The documented error types the page may report; anything else it
    /// reports as `"unknown"` (and the native side maps again, through
    /// `WarmUpOutcome.StreamErrorKind.recognising`).
    static var recognisedStreamErrorTypesJS: String {
        let recognised = WarmUpOutcome.StreamErrorKind.allCases.filter { kind in
            kind != .unknown
        }
        let quoted = recognised.map { kind in
            "\"\(kind.rawValue)\""
        }
        return "[" + quoted.joined(separator: ", ") + "]"
    }

    /// `__streamErrorKind(eventName, data)`: the error type one whole SSE
    /// event carries, or null. `data` is the event's `data:` lines joined
    /// with "\n". An event named `error`, or a payload whose `type` is
    /// `"error"`, is an error; its type is `error.type`, else the payload's
    /// `type`. Only a recognised type is returned as itself; anything else is
    /// `"unknown"`. Exposed so tests can run it in JavaScriptCore.
    static var streamErrorKindJS: String {
        """
        const __recognisedStreamErrors = \(recognisedStreamErrorTypesJS);
        function __streamErrorKind(eventName, data) {
            let parsed = null;
            try { parsed = JSON.parse(data); } catch (e) { parsed = null; }
            const isObject = parsed !== null && typeof parsed === "object";
            const payloadIsError = isObject && parsed.type === "error";
            if (eventName !== "error" && !payloadIsError) { return null; }
            let kind = "unknown";
            if (isObject) {
                if (parsed.error !== null && typeof parsed.error === "object" && typeof parsed.error.type === "string") {
                    kind = parsed.error.type;
                } else if (typeof parsed.type === "string") {
                    kind = parsed.type;
                }
            }
            if (__recognisedStreamErrors.indexOf(kind) < 0) { return "unknown"; }
            return kind;
        }
        """
    }

    /// The peek never waits on the stream's cancellation: `cancel()` is
    /// fired and left to settle, so a stalled cancel cannot stretch the peek
    /// past its deadline. Each chunk is cut to the remaining byte budget
    /// BEFORE it is decoded or scanned.
    static var completionPostScript: String {
        """
        \(streamErrorKindJS)
        if (location.origin !== "https://claude.ai") {
            return { status: 0, retryAfter: null, body: "", streamError: null };
        }
        const response = await fetch(path, {
            method: "POST",
            credentials: "include",
            headers: {
                "Content-Type": "application/json",
                "Accept": "text/event-stream, application/json"
            },
            body: bodyJSON
        });
        let streamError = null;
        if (response.ok && response.body && response.body.getReader) {
            const reader = response.body.getReader();
            const decoder = new TextDecoder();
            const budget = \(streamPeekBytes);
            const deadline = Date.now() + \(streamPeekMilliseconds);
            let received = 0;
            let buffer = "";
            let eventName = null;
            let dataLines = [];
            try {
                scan: while (received < budget) {
                    const remaining = deadline - Date.now();
                    if (remaining <= 0) { break; }
                    let timer = null;
                    const expired = new Promise((resolve) => { timer = setTimeout(() => resolve(null), remaining); });
                    const chunk = await Promise.race([reader.read(), expired]);
                    clearTimeout(timer);
                    if (chunk === null || chunk.done) { break; }
                    let bytes = chunk.value;
                    if (bytes.byteLength > budget - received) {
                        bytes = bytes.subarray(0, budget - received);
                    }
                    received += bytes.byteLength;
                    buffer += decoder.decode(bytes, { stream: true });
                    let newline = buffer.indexOf("\\n");
                    while (newline >= 0) {
                        const line = buffer.slice(0, newline).replace(/\\r$/, "");
                        buffer = buffer.slice(newline + 1);
                        if (line.startsWith("event:")) {
                            eventName = line.slice(6).trim();
                            if (eventName === "message_stop") { break scan; }
                        } else if (line.startsWith("data:")) {
                            let value = line.slice(5);
                            if (value.startsWith(" ")) { value = value.slice(1); }
                            dataLines.push(value);
                        } else if (line === "") {
                            if (eventName !== null || dataLines.length > 0) {
                                const kind = __streamErrorKind(eventName, dataLines.join("\\n"));
                                if (kind !== null) { streamError = kind; break scan; }
                            }
                            eventName = null;
                            dataLines = [];
                        }
                        newline = buffer.indexOf("\\n");
                    }
                }
            } catch (e) {}
            try { reader.cancel().catch(() => {}); } catch (e) {}
        } else {
            try {
                if (response.body) { response.body.cancel().catch(() => {}); }
            } catch (e) {}
        }
        return {
            status: response.status,
            retryAfter: response.headers.get("Retry-After"),
            body: "",
            streamError: streamError
        };
        """
    }

    /// Hard ceiling on a provider response body. Legitimate usage/
    /// conversation payloads are a few KB; 1 MB is far above any real capture
    /// while bounding the memory/main-actor cost of a changed or hostile
    /// endpoint returning an enormous body every poll. Enforced BOTH inside the
    /// evaluated JS (so the oversized body is never fully materialized in the
    /// page) AND here natively (defense-in-depth if the script is bypassed).
    static let maxResponseBytes = 1_048_576

    /// Bounded streaming body read, shared by the Claude and ChatGPT usage
    /// scripts. Reads at most `maxResponseBytes`, cancelling the stream and
    /// returning `null` on overflow (or an oversized declared `Content-Length`)
    /// so the caller surfaces a transient status 0 instead of allocating the
    /// whole payload.
    private static let boundedReadJS = """
    async function __readBounded(response) {
        const MAX = \(maxResponseBytes);
        const declared = parseInt(response.headers.get("Content-Length") || "", 10);
        if (Number.isFinite(declared) && declared > MAX) {
            try { if (response.body) { await response.body.cancel(); } } catch {}
            return null;
        }
        if (response.body && response.body.getReader) {
            const reader = response.body.getReader();
            const chunks = [];
            let received = 0;
            while (true) {
                const { done, value } = await reader.read();
                if (done) break;
                received += value.byteLength;
                if (received > MAX) {
                    try { await reader.cancel(); } catch {}
                    return null;
                }
                chunks.push(value);
            }
            const merged = new Uint8Array(received);
            let offset = 0;
            for (const chunk of chunks) { merged.set(chunk, offset); offset += chunk.byteLength; }
            return new TextDecoder().decode(merged);
        }
        const text = await response.text();
        return text.length > MAX ? null : text;
    }
    """

    private static func envelope(from result: Any?) throws -> WebResponseEnvelope {
        guard
            let dictionary = result as? [String: Any],
            let status = Self.integer(from: dictionary["status"]),
            let body = dictionary["body"] as? String,
            // Native cap: reject an over-large body even if the in-page
            // guard was bypassed or altered.
            body.utf8.count <= maxResponseBytes
        else {
            throw WebUsageClientError.invalidResponse
        }

        let streamErrorType = WarmUpOutcome.StreamErrorKind.recognising(
            dictionary["streamError"] as? String
        )
        return WebResponseEnvelope(
            status: status,
            retryAfter: dictionary["retryAfter"] as? String,
            body: body,
            streamErrorType: streamErrorType
        )
    }

    /// Reads the `lastActiveOrg` cookie — claude.ai's own record of the active
    /// organization (verified non-httpOnly 2026-08-13). Origin-guarded like
    /// every other bridge script. Returns nil when absent/unreadable; the
    /// caller decides how to fall back.
    func lastActiveOrganizationCookie(
        expectedOrigin: String,
        in webView: WKWebView
    ) async throws -> String? {
        let result = try await bounded { [evaluator] in
            try await evaluator(
                Self.lastActiveOrganizationScript,
                ["expectedOrigin": expectedOrigin],
                webView
            )
        }
        guard let value = result as? String, !value.isEmpty else { return nil }
        return value
    }

    private static let lastActiveOrganizationScript = """
    if (location.origin !== expectedOrigin) {
        return null;
    }
    const match = document.cookie.match(/(?:^|;\\s*)lastActiveOrg=([^;]+)/);
    return match ? decodeURIComponent(match[1]) : null;
    """

    func resourcePaths(
        expectedOrigin: String,
        in webView: WKWebView
    ) async throws -> [String] {
        let result = try await bounded { [evaluator] in
            try await evaluator(
                Self.resourcePathsScript,
                ["expectedOrigin": expectedOrigin],
                webView
            )
        }
        guard
            let paths = result as? [String],
            paths.count <= 1_000
        else {
            throw WebUsageClientError.invalidResponse
        }
        return paths
    }

    private static let postScript = """
    if (location.origin !== "https://claude.ai") {
        return { status: 0, retryAfter: null, body: "" };
    }
    const response = await fetch(path, {
        method: "POST",
        credentials: "include",
        headers: {
            "Content-Type": "application/json",
            "Accept": "text/event-stream, application/json"
        },
        body: bodyJSON
    });
    try {
        if (response.body) { await response.body.cancel(); }
    } catch {}
    return {
        status: response.status,
        retryAfter: response.headers.get("Retry-After"),
        body: ""
    };
    """

    private static let fetchScript = """
    if (location.origin !== expectedOrigin) {
        return { status: 0, retryAfter: null, body: "" };
    }
    \(boundedReadJS)
    const response = await fetch(path, {
        credentials: "include",
        headers: { "Accept": "application/json" }
    });
    const body = await __readBounded(response);
    if (body === null) {
        return { status: 0, retryAfter: response.headers.get("Retry-After"), body: "" };
    }
    return {
        status: response.status,
        retryAfter: response.headers.get("Retry-After"),
        body
    };
    """

    private static let chatGPTFetchScript = """
    if (location.origin !== "https://chatgpt.com") {
        return null;
    }
    const __started = Date.now();
    \(boundedReadJS)

    const sessionResponse = await fetch("/api/auth/session", {
        credentials: "include",
        headers: { "Accept": "application/json" }
    });
    if (!sessionResponse.ok) {
        return {
            status: sessionResponse.status,
            retryAfter: null,
            body: ""
        };
    }

    // Bound the auth-session read too — a changed/compromised same-origin
    // endpoint could otherwise return an unbounded body on every poll.
    const sessionText = await __readBounded(sessionResponse);
    if (sessionText === null) {
        return { status: 0, retryAfter: null, body: "" };
    }
    let session;
    try {
        session = JSON.parse(sessionText);
    } catch {
        return { status: 0, retryAfter: null, body: "" };
    }
    const accessToken = session?.accessToken;
    if (typeof accessToken !== "string" || accessToken.length === 0) {
        return { status: 401, retryAfter: null, body: "" };
    }

    let accountID = session?.account?.id;
    if (typeof accountID !== "string" || accountID.length === 0) {
        try {
            const segment = accessToken.split(".")[1]
                .replaceAll("-", "+")
                .replaceAll("_", "/");
            const padded = segment.padEnd(Math.ceil(segment.length / 4) * 4, "=");
            const claims = JSON.parse(atob(padded));
            accountID = claims?.["https://api.openai.com/auth"]
                ?.chatgpt_account_id;
        } catch {}
    }

    const headers = {
        "Accept": "application/json",
        "Authorization": `Bearer ${accessToken}`,
        "OpenAI-Beta": "codex-1"
    };
    if (typeof accountID === "string" && accountID.length > 0) {
        headers["ChatGPT-Account-ID"] = accountID;
    }

    const response = await fetch("/backend-api/wham/usage", {
        credentials: "include",
        headers
    });
    const body = await __readBounded(response);
    if (body === null) {
        return { status: 0, retryAfter: response.headers.get("Retry-After"), body: "", resetCredits: null };
    }

    // Usage-limit resets. Same auth, same page, same bridge evaluation — a
    // second evaluation would add a second hang surface to the fetch-hang
    // machinery. Bounded in-page instead: the abort also cancels a stalled
    // body read, so this can never hold the bridge past its own budget.
    //
    // The abort timer is capped at 10s but SHRUNK under time pressure: a
    // slow session+usage read stacked with a fixed 10s reset timer could
    // otherwise push this WHOLE evaluation past
    // `WebUsageClient.evaluationTimeout` (60s) — which discards the
    // already-successful usage read too, not just the reset read. 50000 =
    // that 60000ms Swift-side timeout minus a 10s return margin (time for
    // the response to actually come back up through the bridge). Under 1s
    // of that budget left, the reset fetch isn't attempted at all.
    let resetCredits = null;
    if (response.ok) {
        const remaining = 50000 - (Date.now() - __started);
        if (remaining < 1000) {
            resetCredits = null;
        } else {
            const controller = new AbortController();
            const timer = setTimeout(() => controller.abort(), Math.min(10000, remaining));
            try {
                const creditsResponse = await fetch("/backend-api/wham/rate-limit-reset-credits", {
                    credentials: "include",
                    headers,
                    signal: controller.signal
                });
                const creditsBody = await __readBounded(creditsResponse);
                if (creditsBody !== null) {
                    resetCredits = { status: creditsResponse.status, body: creditsBody };
                }
            } catch {
                resetCredits = null;
            } finally {
                clearTimeout(timer);
            }
        }
    }
    return {
        status: response.status,
        retryAfter: response.headers.get("Retry-After"),
        body,
        resetCredits
    };
    """

    private static let cursorFetchScript = """
    if (location.origin !== expectedOrigin) {
        return null;
    }
    \(boundedReadJS)

    // Signal "the integration changed" by returning a 200 whose body the native
    // `CursorProviderAdapter.parse` cannot decode. This indirection is
    // load-bearing: cursor.com is an SPA whose catch-all serves ~1.16 MB of HTML
    // with HTTP **200** for a path that no longer exists (live-verified
    // 2026-07-28 against `get-user-usage-summary` / `get-monthly-spend`), so
    // `!response.ok` can NEVER detect a removed endpoint. Validating the decoded
    // shape is the only reliable change signal.
    const CHANGED = { status: 200, retryAfter: null, body: "" };

    function __httpFailure(response) {
        return {
            status: response.status,
            retryAfter: response.headers.get("Retry-After"),
            body: ""
        };
    }

    // 1) Plan tier (same-origin, cookie session). An absent or non-string
    // `membershipType` is a changed integration, not a blank label.
    const stripeResponse = await fetch("/api/auth/stripe", {
        credentials: "include",
        headers: { "Accept": "application/json" }
    });
    if (!stripeResponse.ok) { return __httpFailure(stripeResponse); }
    const stripeText = await __readBounded(stripeResponse);
    if (stripeText === null) { return CHANGED; }
    let stripe;
    try { stripe = JSON.parse(stripeText); } catch { return CHANGED; }
    const membershipType = stripe.membershipType;
    if (typeof membershipType !== "string" || membershipType.length === 0) {
        return CHANGED;
    }

    // 2) Billing-cycle boundaries. `month` is ZERO-INDEXED — live-pinned
    // 2026-07-28: {month:6, year:2026} → 2026-07-01…2026-08-01, while
    // {month:7} → 2026-08-01…2026-09-01. `includeUsageEvents` is IGNORED (the
    // response carries only pricingDescription/periodStartMs/periodEndMs and
    // NEVER an events array), so events are fetched separately below. Both
    // period fields are top-level STRINGS.
    // ONE timestamp for both the month derivation and the containment assert
    // below, so the two can never disagree with each other.
    const nowMs = Date.now();
    const nowDate = new Date(nowMs);
    const invoiceResponse = await fetch("/api/dashboard/get-monthly-invoice", {
        method: "POST",
        credentials: "include",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        body: JSON.stringify({
            month: nowDate.getUTCMonth(),
            year: nowDate.getUTCFullYear()
        })
    });
    if (!invoiceResponse.ok) { return __httpFailure(invoiceResponse); }
    const invoiceText = await __readBounded(invoiceResponse);
    if (invoiceText === null) { return CHANGED; }
    let invoice;
    try { invoice = JSON.parse(invoiceText); } catch { return CHANGED; }
    const periodStartMs = Number.parseInt(String(invoice.periodStartMs), 10);
    const periodEndMs = Number.parseInt(String(invoice.periodEndMs), 10);
    if (
        !Number.isFinite(periodStartMs) ||
        !Number.isFinite(periodEndMs) ||
        periodEndMs <= periodStartMs
    ) {
        return CHANGED;
    }
    // The 0-indexed `month` is an ASSUMPTION about a provider we do not control.
    // Assert the returned invoice is the calendar month asked for — its start
    // lies in that UTC month and is not in the future — so a re-indexing on
    // Cursor's side (or any other interval regression) fails closed instead of
    // publishing a different cycle's spend. Deliberately NOT `now < periodEndMs`:
    // live-observed 2026-08-27, the open invoice reports `periodEndMs` as the
    // server's "now", so that bound holds only by the request's own latency.
    const periodStart = new Date(periodStartMs);
    if (
        periodStartMs > nowMs ||
        periodStart.getUTCFullYear() !== nowDate.getUTCFullYear() ||
        periodStart.getUTCMonth() !== nowDate.getUTCMonth()
    ) {
        return CHANGED;
    }

    // 3) Sum chargeable spend WITHIN [periodStartMs, periodEndMs).
    // There is NO server-side date filter (live-pinned: {startDate, endDate}
    // returns an empty object; {startDateMs, endDateMs} and {month, year} are
    // silently ignored and byte-identical to {}), so the cycle bound is applied
    // HERE — an unfiltered sum would report arbitrary historical spend. Events
    // arrive DESCENDING by timestamp and `page`/`pageSize` compose (1-based),
    // so the walk stops at the first event older than the cycle start.
    // `chargedCents` is FRACTIONAL — accumulate, then round once.
    //
    // Every field the total DEPENDS on is validated, because a silently
    // undercounted total is indistinguishable from real thrift: a renamed
    // `timestamp`/`isChargeable`/`chargedCents`, or a page that contradicts the
    // declared count, reports `integrationChanged` rather than a smaller number.
    const PAGE_SIZE = 250;
    const MAX_PAGES = 20;
    let spentCents = 0;
    let cycleFullyCovered = false;
    let consumed = 0;
    let declaredTotal = null;
    let previousTimestamp = Infinity;
    for (let page = 1; page <= MAX_PAGES && !cycleFullyCovered; page++) {
        const eventsResponse = await fetch("/api/dashboard/get-filtered-usage-events", {
            method: "POST",
            credentials: "include",
            headers: { "Content-Type": "application/json", "Accept": "application/json" },
            body: JSON.stringify({ page, pageSize: PAGE_SIZE })
        });
        if (!eventsResponse.ok) { return __httpFailure(eventsResponse); }
        const eventsText = await __readBounded(eventsResponse);
        if (eventsText === null) { return CHANGED; }
        let eventsPayload;
        try { eventsPayload = JSON.parse(eventsText); } catch { return CHANGED; }
        const events = eventsPayload.usageEventsDisplay;
        if (!Array.isArray(events)) { return CHANGED; }

        // `totalUsageEventsCount` is the completeness authority. It must be
        // present, and stable across the walk — a total that moves mid-walk means
        // the underlying list mutated and offset pages can no longer be trusted
        // to tile it exactly.
        const pageTotal = Number(eventsPayload.totalUsageEventsCount);
        if (!Number.isFinite(pageTotal) || pageTotal < 0) { return CHANGED; }
        if (declaredTotal === null) { declaredTotal = pageTotal; }
        if (pageTotal !== declaredTotal) { return CHANGED; }
        consumed += events.length;

        for (const event of events) {
            if (!event || typeof event !== "object") { return CHANGED; }
            const timestamp = Number(event.timestamp);
            if (!Number.isFinite(timestamp)) { return CHANGED; }
            // Descending order is what makes the early exit sound. Validate it
            // across page boundaries too, not just within a page.
            if (timestamp > previousTimestamp) { return CHANGED; }
            previousTimestamp = timestamp;

            if (timestamp < periodStartMs) { cycleFullyCovered = true; continue; }
            if (timestamp >= periodEndMs) { continue; }
            // In-cycle: this event can move the total, so its shape must be exact.
            if (typeof event.isChargeable !== "boolean") { return CHANGED; }
            if (!event.isChargeable) { continue; }
            const cents = Number(event.chargedCents);
            if (!Number.isFinite(cents)) { return CHANGED; }
            spentCents += cents;
        }

        // A short page means the history is exhausted — which is only coherent if
        // the walk consumed EXACTLY the declared total. `{count: 518, events: []}`
        // would otherwise read as "no spend" instead of a changed integration.
        if (events.length < PAGE_SIZE) {
            if (consumed !== declaredTotal) { return CHANGED; }
            cycleFullyCovered = true;
        }
    }
    // Never report a total that might be missing cycle events: silently
    // understating spend would be fabricated data.
    if (!cycleFullyCovered) { return CHANGED; }

    const result = JSON.stringify({
        membershipType,
        periodStartMs,
        periodEndMs,
        spentCents: Math.round(spentCents)
    });
    return { status: 200, retryAfter: null, body: result };
    """

    /// Page cap for one history walk: 40 × 250 = 10 000 events. A walk that
    /// stops here reports only the cycles it fully covered.
    static let cursorHistoryMaxPages = 40

    /// Past-cycle totals, built from the SAME two endpoints and the SAME guards
    /// as `cursorFetchScript` (docs/provider-contracts/cursor.md):
    /// `get-monthly-invoice` per requested month for the boundaries, then ONE
    /// descending walk of `get-filtered-usage-events` that sums each chargeable
    /// event into the cycle whose `[periodStartMs, periodEndMs)` holds it.
    ///
    /// Arguments: `expectedOrigin`, `months` (`[{year, month}]`, month
    /// 0-indexed, newest first), `currentPeriodStartMs` (the open cycle, which
    /// no past cycle may reach into) and `pauseMs` (between requests).
    ///
    /// Fails closed (`CHANGED`, or the HTTP failure) on: a month whose invoice
    /// starts outside that UTC month, has not ended yet, or overlaps another;
    /// any malformed event; a page that breaks descending order; or a
    /// `totalUsageEventsCount` that moves during the walk. Otherwise it returns
    /// `{cycles, historyExhausted, oldestEventMs}`, where `cycles` holds only
    /// the cycles whose every event was seen.
    private static let cursorHistoryScript = """
    if (location.origin !== expectedOrigin) {
        return null;
    }
    \(boundedReadJS)

    // The same "integration changed" signal as `cursorFetchScript`: a 200 whose
    // body the native parser cannot decode (cursor.com answers a removed path
    // with 200 + HTML, so the status alone proves nothing).
    const CHANGED = { status: 200, retryAfter: null, body: "" };

    function __httpFailure(response) {
        return {
            status: response.status,
            retryAfter: response.headers.get("Retry-After"),
            body: ""
        };
    }

    async function __pause() {
        const ms = Number(pauseMs);
        if (Number.isFinite(ms) && ms > 0) {
            await new Promise(function (resolve) { setTimeout(resolve, ms); });
        }
    }

    // Strict readers for the documented fields: a value of any other type
    // (null, a boolean, a non-numeric string, NaN) is null, and the caller
    // fails closed — never a silent 0.
    function __msString(value) {
        return (typeof value === "string" && /^[0-9]{1,16}$/.test(value)) ? Number(value) : null;
    }
    function __timestamp(value) {
        if (typeof value === "number") {
            return (Number.isFinite(value) && value >= 0) ? value : null;
        }
        return __msString(value);
    }
    function __finiteNumber(value) {
        return (typeof value === "number" && Number.isFinite(value)) ? value : null;
    }
    function __count(value) {
        return (typeof value === "number" && Number.isInteger(value) && value >= 0) ? value : null;
    }

    async function __postJSON(path, payload) {
        return await fetch(path, {
            method: "POST",
            credentials: "include",
            headers: { "Content-Type": "application/json", "Accept": "application/json" },
            body: JSON.stringify(payload)
        });
    }

    const nowMs = Date.now();
    const openStartMs = Number(currentPeriodStartMs);
    if (!Number.isFinite(openStartMs) || !Array.isArray(months) || months.length === 0 || months.length > 12) {
        return CHANGED;
    }

    // 1) Each past month's invoice boundaries. `month` is ZERO-INDEXED
    // (live-pinned 2026-07-28), both fields are top-level strings.
    const cycles = [];
    for (const wanted of months) {
        const year = Number(wanted && wanted.year);
        const month = Number(wanted && wanted.month);
        if (!Number.isInteger(year) || !Number.isInteger(month) || month < 0 || month > 11) {
            return CHANGED;
        }
        if (cycles.length > 0) { await __pause(); }
        const invoiceResponse = await __postJSON("/api/dashboard/get-monthly-invoice", { month, year });
        if (!invoiceResponse.ok) { return __httpFailure(invoiceResponse); }
        const invoiceText = await __readBounded(invoiceResponse);
        if (invoiceText === null) { return CHANGED; }
        let invoice;
        try { invoice = JSON.parse(invoiceText); } catch { return CHANGED; }
        if (!invoice || typeof invoice !== "object") { return CHANGED; }
        const startMs = __msString(invoice.periodStartMs);
        const endMs = __msString(invoice.periodEndMs);
        if (startMs === null || endMs === null || endMs <= startMs) {
            return CHANGED;
        }
        // A CLOSED invoice is exactly the UTC calendar month asked for: it
        // starts at that month's first instant and ends at the next month's
        // (the contract's live-pinned calendar-month boundaries). Anything
        // else — a re-indexed `month`, an end short of the boundary that would
        // freeze a partial total, an end still moving — fails closed.
        if (startMs !== Date.UTC(year, month, 1) || endMs !== Date.UTC(year, month + 1, 1)) {
            return CHANGED;
        }
        // ... and it has ended, before the open cycle.
        if (endMs > nowMs || endMs > openStartMs) {
            return CHANGED;
        }
        cycles.push({ startMs, endMs, cents: 0 });
    }
    cycles.sort(function (a, b) { return b.startMs - a.startMs; });
    for (let i = 1; i < cycles.length; i++) {
        // Newest first: each cycle must end at or before the next newer one
        // starts, or one event could count twice.
        if (cycles[i].endMs > cycles[i - 1].startMs) { return CHANGED; }
    }
    const oldestStartMs = cycles[cycles.length - 1].startMs;

    // 2) One descending walk over the events. No server-side date filter
    // exists (live-pinned), so the cycle bounds are applied here; descending
    // order makes the early stop at the oldest cycle's start sound.
    // `chargedCents` is FRACTIONAL — accumulate, round each total once.
    const PAGE_SIZE = 250;
    const MAX_PAGES = \(cursorHistoryMaxPages);
    let consumed = 0;
    let declaredTotal = null;
    let previousTimestamp = Infinity;
    let oldestSeenMs = null;
    let exhausted = false;
    let reachedOldest = false;
    // Offset pages over a list that changed under a constant count can hand
    // back the same event twice. Every event's documented fields form its
    // key; a key seen twice fails closed rather than counting twice.
    const seenKeys = new Set();
    function __eventKey(event, timestamp) {
        return JSON.stringify([
            timestamp, event.model, event.kind, event.isChargeable,
            event.chargedCents, event.usageBasedCosts, event.requestsCosts
        ]);
    }
    // One page, validated as far as its shape: `{events, total}`, or an
    // envelope to return as-is (HTTP failure / CHANGED).
    async function __page(page) {
        const eventsResponse = await __postJSON("/api/dashboard/get-filtered-usage-events", { page, pageSize: PAGE_SIZE });
        if (!eventsResponse.ok) { return { failure: __httpFailure(eventsResponse) }; }
        const eventsText = await __readBounded(eventsResponse);
        if (eventsText === null) { return { failure: CHANGED }; }
        let eventsPayload;
        try { eventsPayload = JSON.parse(eventsText); } catch { return { failure: CHANGED }; }
        if (!eventsPayload || typeof eventsPayload !== "object") { return { failure: CHANGED }; }
        const events = eventsPayload.usageEventsDisplay;
        if (!Array.isArray(events)) { return { failure: CHANGED }; }
        return { events, total: __count(eventsPayload.totalUsageEventsCount) };
    }
    // Page 1's events in order, as first read — re-read at the end of a
    // multi-page walk (see below).
    const firstPageKeys = [];
    let pagesRead = 0;
    for (let page = 1; page <= MAX_PAGES && !exhausted && !reachedOldest; page++) {
        await __pause();
        const read = await __page(page);
        if (read.failure) { return read.failure; }
        const events = read.events;
        pagesRead += 1;

        // `totalUsageEventsCount` must be present and stable across the walk:
        // a total that moves means the list mutated under the offset pages.
        const pageTotal = read.total;
        if (pageTotal === null) { return CHANGED; }
        if (declaredTotal === null) { declaredTotal = pageTotal; }
        if (pageTotal !== declaredTotal) { return CHANGED; }
        consumed += events.length;
        if (consumed > declaredTotal) { return CHANGED; }

        for (const event of events) {
            if (!event || typeof event !== "object") { return CHANGED; }
            const timestamp = __timestamp(event.timestamp);
            if (timestamp === null) { return CHANGED; }
            if (timestamp > previousTimestamp) { return CHANGED; }
            previousTimestamp = timestamp;
            oldestSeenMs = timestamp;
            const key = __eventKey(event, timestamp);
            if (seenKeys.has(key)) { return CHANGED; }
            seenKeys.add(key);
            if (page === 1) { firstPageKeys.push(key); }

            if (timestamp < oldestStartMs) { reachedOldest = true; continue; }
            let target = null;
            for (const cycle of cycles) {
                if (timestamp >= cycle.startMs && timestamp < cycle.endMs) { target = cycle; break; }
            }
            // The open cycle (or a gap between invoices): not ours to count.
            if (target === null) { continue; }
            if (typeof event.isChargeable !== "boolean") { return CHANGED; }
            if (!event.isChargeable) { continue; }
            const cents = __finiteNumber(event.chargedCents);
            if (cents === null) { return CHANGED; }
            target.cents += cents;
        }

        // A short page ends the list — coherent only if the walk consumed
        // EXACTLY the declared total.
        if (events.length < PAGE_SIZE) {
            if (consumed !== declaredTotal) { return CHANGED; }
            exhausted = true;
        }
        // A full page that consumed exactly the declared total also ends
        // the list (10 000 events = 40 full pages, no empty 41st to ask for).
        if (consumed === declaredTotal) { exhausted = true; }
    }

    // A deletion among events already read plus an insertion farther down
    // keeps the count constant and shifts the later offset pages by one, so a
    // page can skip an event that no order or duplicate check sees. Re-read
    // page 1: the list must still start with exactly the events it started
    // with, in the same order, under the same count, or nothing is reported.
    if (pagesRead > 1) {
        await __pause();
        const again = await __page(1);
        if (again.failure) { return again.failure; }
        if (again.total !== declaredTotal) { return CHANGED; }
        const againKeys = [];
        for (const event of again.events) {
            if (!event || typeof event !== "object") { return CHANGED; }
            const timestamp = __timestamp(event.timestamp);
            if (timestamp === null) { return CHANGED; }
            againKeys.push(__eventKey(event, timestamp));
        }
        if (JSON.stringify(againKeys) !== JSON.stringify(firstPageKeys)) { return CHANGED; }
    }

    // A cycle is complete once an OLDER event has been seen (descending
    // order: every event of it came before), or the list ran out. Anything
    // else stays out — a partial total is never reported.
    const covered = [];
    for (const cycle of cycles) {
        const complete = exhausted || (oldestSeenMs !== null && oldestSeenMs < cycle.startMs);
        if (complete) {
            covered.push({
                periodStartMs: cycle.startMs,
                periodEndMs: cycle.endMs,
                spentCents: Math.round(cycle.cents)
            });
        }
    }
    const result = JSON.stringify({
        cycles: covered,
        historyExhausted: exhausted,
        oldestEventMs: oldestSeenMs
    });
    return { status: 200, retryAfter: null, body: result };
    """

    private static let resourcePathsScript = """
    if (location.origin !== expectedOrigin) {
        return [];
    }
    return performance.getEntriesByType("resource").map(entry => {
        try {
            const url = new URL(entry.name);
            return url.origin === location.origin ? url.pathname : null;
        } catch {
            return null;
        }
    }).filter(path => path !== null);
    """

    private static func liveEvaluator(
        script: String,
        arguments: [String: Any],
        webView: WKWebView
    ) async throws -> Any? {
        // `.defaultClient`, not `.page`: run the app's bridge scripts in an
        // isolated content world so page-owned globals (a monkey-patched
        // `fetch`, `performance`, `JSON`, `atob`) cannot tamper with what the
        // app observes or sends. Cookies are per-origin, not per-world, so
        // `credentials: "include"` still authenticates. (Apple's recommended
        // isolation; see WKContentWorld docs.)
        try await webView.callAsyncJavaScript(
            script,
            arguments: arguments,
            in: nil,
            contentWorld: .defaultClient
        )
    }

    private static func integer(from value: Any?) -> Int? {
        if let integer = value as? Int {
            return integer
        }
        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }
}
