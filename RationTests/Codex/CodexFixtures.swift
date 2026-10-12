import Foundation
@testable import Ration

/// Realistic `~/.codex/auth.json` files, shaped like the ones Codex writes (spec §2):
/// Codex's own pretty layout and key order, a synthetic id token whose
/// payload carries the claims Codex reads. Never a real token.
enum CodexFixtures {
    static let authClaim = "https://api.openai.com/auth"

    /// A ChatGPT login; `lastRefresh` and `refreshToken` vary the bytes of
    /// one login the way a Codex token refresh does.
    static func authJSON(accountID: String = "acct-A", userID: String = "user-1", email: String? = "a@example.com",
                         planType: String? = "pro", lastRefresh: String = "2026-10-11T18:00:00.000000Z",
                         refreshToken: String = "rt-A") -> Data {
        file(idToken: idToken(claims(accountID: accountID, userID: userID, email: email, planType: planType)),
             tokensAccountID: accountID, lastRefresh: lastRefresh, refreshToken: refreshToken)
    }

    /// An API-key login: unsupported.
    static func apiKeyJSON() -> Data {
        Data("{\n  \"auth_mode\": \"apikey\",\n  \"OPENAI_API_KEY\": \"sk-test-not-a-key\"\n}".utf8)
    }

    /// The id token's payload as Codex reads it (`token_data.rs`).
    static func claims(accountID: String?, userID: String?, email: String? = "a@example.com", planType: String? = "pro") -> [String: Any] {
        var auth: [String: Any] = [:]
        auth["chatgpt_account_id"] = accountID
        auth["chatgpt_user_id"] = userID
        auth["user_id"] = userID
        auth["chatgpt_plan_type"] = planType
        var claims: [String: Any] = ["iss": "https://auth.openai.com", "sub": "auth0|synthetic", "exp": 1_791_000_000, authClaim: auth]
        claims["email"] = email
        return claims
    }

    /// `header.payload.signature`, base64url without padding.
    static func idToken(_ claims: [String: Any]) -> String {
        let header = base64URL(Data(#"{"alg":"RS256","typ":"JWT"}"#.utf8))
        let payload = base64URL((try? JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])) ?? Data())
        return "\(header).\(payload).c2lnbmF0dXJl"
    }

    /// The whole file in Codex's layout (`serde_json` pretty, struct order).
    static func file(idToken: String, tokensAccountID: String?, lastRefresh: String? = "2026-10-11T18:00:00.000000Z",
                     refreshToken: String = "rt-A", authMode: String? = "chatgpt") -> Data {
        var tokens = ["    \"id_token\": \(quoted(idToken))", "    \"access_token\": \(quoted("at-\(refreshToken)"))",
                      "    \"refresh_token\": \(quoted(refreshToken))"]
        if let tokensAccountID { tokens.append("    \"account_id\": \(quoted(tokensAccountID))") }
        var lines: [String] = []
        if let authMode { lines.append("  \"auth_mode\": \(quoted(authMode))") }
        lines.append("  \"OPENAI_API_KEY\": null")
        lines.append("  \"tokens\": {\n\(tokens.joined(separator: ",\n"))\n  }")
        if let lastRefresh { lines.append("  \"last_refresh\": \(quoted(lastRefresh))") }
        return Data("{\n\(lines.joined(separator: ",\n"))\n}".utf8)
    }

    /// A login decoded from fixture bytes (known to decode).
    static func login(_ bytes: Data) -> CodexLogin {
        // swiftlint:disable:next force_try
        try! CodexLogin(fileBytes: bytes)
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: text, options: [.fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
