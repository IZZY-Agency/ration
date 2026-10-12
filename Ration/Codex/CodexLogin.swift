import Foundation

/// The login `~/.codex/auth.json` holds (spec §4.1): the file's bytes as
/// read — a switch writes them back unchanged — and who they sign in,
/// read from the id token's payload. Codex wrote the file on this Mac, so
/// its claims only name and link the login; they grant nothing.
struct CodexLogin: Equatable, Sendable {
    let bytes: Data
    /// `https://api.openai.com/auth`.`chatgpt_account_id`, else `tokens.account_id`:
    /// the workspace, shared by every seat of a Team.
    let accountID: String
    /// `https://api.openai.com/auth`.`chatgpt_user_id`, else its `user_id`
    /// (Codex's own fallback), else a top-level `user_id`.
    let userID: String
    /// Display only, never a key.
    let email: String?
    /// `chatgpt_plan_type`, e.g. "pro", "plus", "prolite".
    let planType: String?
    /// The file's `last_refresh` as written (RFC 3339 text), nil when absent.
    let lastRefresh: String?

    /// `"<accountID>|<userID>"` — the key for everything: Keychain item,
    /// link, journal, log, prompt, switch request (spec §4.1). Two seats of
    /// one workspace share the account id; the user id tells them apart.
    var id: String { Self.id(accountID: accountID, userID: userID) }

    static func id(accountID: String, userID: String) -> String { "\(accountID)|\(userID)" }

    enum Failure: Error, Equatable, Sendable {
        /// Not JSON, or the id token is not a decodable JWT. Codex writes the
        /// file in place, so a read can catch it half-written: retry once.
        case unreadable
        /// `auth_mode` is not "chatgpt", or there is no `tokens.id_token`
        /// (an API-key login, the keyring store, an empty file).
        case unsupported
        /// Parses, but is not one whole login: `tokens.account_id` disagrees
        /// with the id token's account, or the token names no account or no
        /// user — the mixed file a refresh racing a switch leaves (spec §2).
        case damaged
    }

    static let authClaim = "https://api.openai.com/auth"
    static let profileClaim = "https://api.openai.com/profile"

    /// Never returns a login without an account id and a user id.
    init(fileBytes: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: fileBytes) as? [String: Any] else { throw Failure.unreadable }
        // Codex's own reading: an explicit mode wins; a file written before
        // Codex recorded one is an API-key login when it holds a key.
        if let mode = object["auth_mode"] {
            guard mode as? String == "chatgpt" else { throw Failure.unsupported }
        } else if object["OPENAI_API_KEY"] is String {
            throw Failure.unsupported
        }
        guard let tokens = object["tokens"] as? [String: Any], let idToken = tokens["id_token"] as? String else {
            throw Failure.unsupported
        }
        let claims = try Self.payload(ofJWT: idToken)
        let auth = claims[Self.authClaim] as? [String: Any]
        let fileAccount = Self.nonEmpty(tokens["account_id"])
        let tokenAccount = Self.nonEmpty(auth?["chatgpt_account_id"])
        if let fileAccount, let tokenAccount, fileAccount != tokenAccount { throw Failure.damaged }
        guard let accountID = tokenAccount ?? fileAccount,
              let userID = Self.nonEmpty(auth?["chatgpt_user_id"]) ?? Self.nonEmpty(auth?["user_id"]) ?? Self.nonEmpty(claims["user_id"])
        else { throw Failure.damaged }

        bytes = fileBytes
        self.accountID = accountID
        self.userID = userID
        email = Self.nonEmpty(claims["email"]) ?? Self.nonEmpty((claims[Self.profileClaim] as? [String: Any])?["email"])
        planType = Self.nonEmpty(auth?["chatgpt_plan_type"])
        lastRefresh = object["last_refresh"] as? String
    }

    /// The middle part of `header.payload.signature`, base64url.
    private static func payload(ofJWT jwt: String) throws -> [String: Any] {
        let parts = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw Failure.unreadable }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw Failure.unreadable }
        return claims
    }

    private static func nonEmpty(_ value: Any?) -> String? {
        guard let text = value as? String, !text.isEmpty else { return nil }
        return text
    }
}
