import Foundation
import WebKit

/// Sends a minimal "keep-alive" message to Claude to start the 5-hour usage
/// window at reset. First write action in the app; used only for opted-in
/// accounts. Everything happens inside the account's isolated WebKit session.
///
/// Split into `prepare` (read-only discovery) and `send` (the one irreversible
/// POST) so the caller can durably reserve the attempt between the two.
@MainActor
struct ClaudeMessageSender {
    enum SendError: Error, Equatable {
        case organizationNotFound
        case modelNotFound
        case transport
        case rejected(status: Int)
    }

    struct Prepared: Equatable {
        let organizationID: String
        let model: String
    }

    private let client: WebUsageClient
    private let organizationResolver: ClaudeOrganizationResolver

    init(
        client: WebUsageClient = WebUsageClient(),
        organizationResolver: ClaudeOrganizationResolver? = nil
    ) {
        self.client = client
        self.organizationResolver = organizationResolver
            ?? ClaudeOrganizationResolver(client: client)
    }

    /// Read-only discovery: the exact organization the usage read used, and a
    /// currently-valid model string from the account's own conversations. Safe
    /// to retry (no writes).
    ///
    /// `boundToOrganizationID` is the org the TRIGGERING snapshot's data
    /// actually came from (`UsageSnapshot.organizationID`, carried in memory
    /// from the adapter's fetch) — the irreversible send is structurally
    /// bound to it; no discovery runs and no shared state can redirect it.
    /// The policy layer (`handleAutoStart`) FAILS CLOSED before calling this
    /// when its snapshot carries no org. Live discovery runs only for
    /// explicitly UNBOUND calls (nil — the manual debug send after a failed
    /// warm-up), where "whatever workspace is active right now" IS the
    /// user's stated intent.
    func prepare(
        boundToOrganizationID: String? = nil,
        in webView: WKWebView
    ) async throws -> Prepared {
        let organizationID: String
        if let boundToOrganizationID {
            organizationID = boundToOrganizationID
        } else {
            organizationID = try await discoverOrganizationID(in: webView)
        }
        let model = try await discoverModel(
            organizationID: organizationID,
            in: webView
        )
        return Prepared(organizationID: organizationID, model: model)
    }

    /// The single irreversible send. Reuses `conversationID` when supplied;
    /// on a 404 (the stored keep-alive conversation was deleted) retries once
    /// with a fresh id, since the completion POST creates the conversation.
    /// Returns the conversation id actually used, to be persisted.
    @discardableResult
    func send(
        prepared: Prepared,
        conversationID: UUID?,
        prompt: String = "Keeping this window active.",
        in webView: WKWebView
    ) async throws -> UUID {
        // The completion endpoint 404s on an unknown conversation — it does not
        // auto-create — so ensure the keep-alive conversation exists first.
        let conversation: UUID
        if let conversationID {
            conversation = conversationID
        } else {
            conversation = try await createConversation(prepared: prepared, in: webView)
        }
        let status = try await postCompletion(
            prepared: prepared,
            conversation: conversation,
            prompt: prompt,
            in: webView
        )
        if status == 404 {
            // Stored conversation is gone (deleted or stale) — create a fresh one
            // and retry the completion once.
            let fresh = try await createConversation(prepared: prepared, in: webView)
            let retryStatus = try await postCompletion(
                prepared: prepared,
                conversation: fresh,
                prompt: prompt,
                in: webView
            )
            guard (200..<300).contains(retryStatus) else {
                throw SendError.rejected(status: retryStatus)
            }
            return fresh
        }
        guard (200..<300).contains(status) else {
            throw SendError.rejected(status: status)
        }
        return conversation
    }

    /// Creates the reusable keep-alive conversation with a client-generated uuid.
    private func createConversation(
        prepared: Prepared,
        in webView: WKWebView
    ) async throws -> UUID {
        // Check right before the POST so a cancelled auto-start does not create
        // a stray blank conversation on the account.
        try Task.checkCancellation()
        let uuid = UUID()
        let body: [String: Any] = [
            "uuid": uuid.uuidString.lowercased(),
            "name": "Ration keep-alive"
        ]
        let path = "/api/organizations/\(prepared.organizationID)/chat_conversations"
        let status: Int
        do {
            status = try await client.postJSON(
                path: path,
                bodyJSON: try Self.jsonString(from: body),
                in: webView
            ).status
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SendError {
            throw error
        } catch let error as WebUsageClientError where error == .timedOut {
            // Pass the timeout through untouched — AccountSessionManager
            // recycles the web view on it; the refresh coordinator's generic
            // catch maps it to .transport afterwards.
            throw error
        } catch {
            throw SendError.transport
        }
        guard (200..<300).contains(status) else {
            throw SendError.rejected(status: status)
        }
        return uuid
    }

    private func postCompletion(
        prepared: Prepared,
        conversation: UUID,
        prompt: String,
        in webView: WKWebView
    ) async throws -> Int {
        // Check right before the irreversible POST so a cancelled auto-start
        // (e.g. account removal mid-refresh) cannot send.
        try Task.checkCancellation()
        let body: [String: Any] = [
            "prompt": prompt,
            "model": prepared.model,
            "timezone": TimeZone.current.identifier,
            "rendering_mode": "messages",
            "attachments": [],
            "files": [],
            "sync_sources": [],
            "tools": []
        ]
        let path = "/api/organizations/\(prepared.organizationID)"
            + "/chat_conversations/\(conversation.uuidString.lowercased())/completion"
        do {
            return try await client.postJSON(
                path: path,
                bodyJSON: try Self.jsonString(from: body),
                in: webView
            ).status
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SendError {
            throw error
        } catch let error as WebUsageClientError where error == .timedOut {
            // Pass the timeout through untouched — AccountSessionManager
            // recycles the web view on it; the refresh coordinator's generic
            // catch maps it to .transport afterwards.
            throw error
        } catch {
            throw SendError.transport
        }
    }

    /// Delegates to the shared resolver (cookie → `/api/organizations` →
    /// resource-entry scrape). Uncached (`cacheKey: nil`): auto-start runs at
    /// most a handful of times a day and must never act on a stale org for an
    /// irreversible send.
    private func discoverOrganizationID(in webView: WKWebView) async throws -> String {
        do {
            return try await organizationResolver.organizationID(
                cacheKey: nil,
                in: webView
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as WebUsageClientError where error == .timedOut {
            // The bound must surface — the caller (AccountSessionManager)
            // recycles the web view on it.
            throw error
        } catch let ClaudeOrganizationResolver.ResolutionError.authenticationRequired(status) {
            // A signed-out session keeps the sender's long-standing auth
            // contract: surface the exact status so the caller can tell the
            // user to sign in rather than silently skipping auto-start.
            throw SendError.rejected(status: status)
        } catch {
            // Every other failure keeps degrading to organizationNotFound,
            // unchanged from before.
            throw SendError.organizationNotFound
        }
    }

    /// Reads a currently-valid model string from the account's own conversations
    /// rather than hardcoding one (the capture redacts model values).
    ///
    /// The read is bounded with `?limit=` so a heavy account's full conversation
    /// list (which can exceed `WebUsageClient.maxResponseBytes`, the 1 MB cap)
    /// cannot overflow the cap. Before this bound, an oversize list was zeroed by
    /// the cap (`status:0`, empty body); the empty body then failed the JSON-array
    /// parse and surfaced — misleadingly — as `modelNotFound`, blocking auto-start
    /// on every poll for such accounts.
    private func discoverModel(
        organizationID: String,
        in webView: WKWebView
    ) async throws -> String {
        let envelope = try await client.fetch(
            path: "/api/organizations/\(organizationID)"
                + "/chat_conversations?limit=\(Self.modelDiscoveryLimit)",
            expectedOrigin: Provider.claude.webOrigin,
            in: webView
        )
        // A non-2xx read is a read failure, NOT "no model exists":
        //  - the cap sentinel `status:0` (body over the 1 MB limit, or an origin
        //    guard trip) is transient — retry;
        //  - a real HTTP status is preserved so the caller can distinguish a
        //    genuine auth rejection (401/403 → tell the user to sign in) from a
        //    transient server error (5xx → retry). Never `modelNotFound` here.
        guard (200..<300).contains(envelope.status) else {
            if envelope.status == 0 {
                throw SendError.transport
            }
            throw SendError.rejected(status: envelope.status)
        }
        // A 2xx body that is not the expected JSON array is an unexpected /
        // changed response shape — surface it (`modelNotFound`) rather than
        // silently sending with a default, since the send is irreversible.
        guard
            let data = envelope.body.data(using: .utf8),
            let conversations = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else {
            throw SendError.modelNotFound
        }
        // Bound the scan and validate the discovered value. This string is
        // interpolated into the irreversible completion request, so cap the
        // array scanned, cap the length, and require a conservative model-id
        // shape (alphanumerics and `-_.:` only) — a hostile/changed page cannot
        // then drive an arbitrary or huge `model` into the send.
        for conversation in conversations.prefix(Self.maxConversationsScanned) {
            if
                let model = conversation["model"] as? String,
                Self.isPlausibleModel(model)
            {
                return model
            }
        }
        // A well-formed array with no usable `model` (a brand-new account with no
        // conversations, or none carrying a plausible model): fall back to a
        // known-good default so a fresh account can still start its window. The
        // keep-alive only needs a model the account can use; if it can't, the
        // completion POST surfaces an honest `rejected(status:)` instead.
        return Self.fallbackModel
    }

    private static let maxConversationsScanned = 500
    private static let maxModelLength = 200

    /// Upper bound on the conversation-list read used only to discover a model
    /// string. Small enough that even a heavy account's response stays well under
    /// the 1 MB cap, large enough to tolerate a few recent conversations whose
    /// `model` is missing/implausible.
    private static let modelDiscoveryLimit = 10

    /// Last-resort model when the account has no conversation carrying a usable
    /// `model`. A broadly-available current model; kept as a single constant so
    /// it is trivial to refresh. Must satisfy `isPlausibleModel`.
    static let fallbackModel = "claude-haiku-4-5-20251001"

    static func isPlausibleModel(_ model: String) -> Bool {
        guard !model.isEmpty, model.count <= maxModelLength else { return false }
        // ASCII-only by explicit scalar range: `Character.isLetter`/`.isNumber`
        // accept non-ASCII Unicode letters/digits (e.g. Cyrillic homoglyphs),
        // which the intended `[A-Za-z0-9-_.:]` model-id contract must reject.
        return model.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9":
                return true
            case "-", "_", ".", ":":
                return true
            default:
                return false
            }
        }
    }

    private static func jsonString(from body: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        guard let string = String(data: data, encoding: .utf8) else {
            throw SendError.transport
        }
        return string
    }
}
