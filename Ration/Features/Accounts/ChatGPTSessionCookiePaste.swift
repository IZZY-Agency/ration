import Foundation

/// Pasted-session-cookie support for passkey-only OpenAI accounts.
///
/// WebAuthn/passkeys cannot complete inside a `WKWebView` unless the app
/// carries Apple's restricted `com.apple.developer.web-browser.public-key-credential`
/// entitlement (paid Developer Program + Apple-approved capability — this app
/// is ad-hoc signed). Until that route exists, the sign-in window lets the
/// user log in at chatgpt.com in their REAL browser and paste the session
/// cookie here; the app writes it into the account's isolated cookie store
/// and the normal `verifySession` path remains the authority on whether the
/// pasted session actually works.
///
/// Cookie names live-pinned 2026-08-14 from this app's own ChatGPT profile
/// store: the credential is `__Secure-next-auth.session-token` on
/// `.chatgpt.com` (Secure, HttpOnly); `_account` (Secure, page-readable)
/// selects the workspace. Everything else (Cloudflare et al.) the web view
/// earns on its own.
enum SessionCookiePasteError: Error, Equatable {
    /// Only chatgpt.com sessions accept pasted cookies — every other
    /// provider's web sign-in works without passkeys.
    case unsupportedProvider
    /// The paste contained nothing that could be a session cookie.
    case nothingToApply
    /// The paste carried cookie pairs but not the actual credential —
    /// reporting success would install no authentication at all.
    case missingSessionToken
}

enum ChatGPTSessionCookiePaste {
    static let sessionTokenName = "__Secure-next-auth.session-token"
    static let cookieDomain = ".chatgpt.com"
    /// Comfortably outlives the server-side session validity (~90 days) so
    /// the cookie jar never expires a still-valid session.
    static let validity: TimeInterval = 90 * 24 * 3600

    /// A cookie NAME can plausibly be this long; anything longer on the left
    /// of an `=` is a token blob mis-split at its base64 padding.
    private static let maxPlausibleNameLength = 64
    /// A bare segment shorter than this (and without the dots of a JWE) is a
    /// leftover like `name=`, not a session token — dropped rather than sent.
    private static let bareValueMinimumLength = 40

    struct Parsed: Equatable {
        let name: String
        let value: String
    }

    /// Forgiving parse of what users realistically paste: the bare token
    /// value from the DevTools cookie inspector, a `name=value` pair, or a
    /// whole `Cookie:` header line. Returns `[]` when nothing usable remains.
    static func parse(_ raw: String) -> [Parsed] {
        var input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.lowercased().hasPrefix("cookie:") {
            input.removeFirst("cookie:".count)
        }
        // Whitespace is a SAFE separator alongside `;`: RFC 6265 cookie
        // names and values can never contain spaces, and the masked
        // single-line paste field flattens multi-line pastes into spaces.
        let segments = input
            .components(separatedBy: CharacterSet.whitespacesAndNewlines.union(
                CharacterSet(charactersIn: ";")
            ))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .map(strippingWrappingQuotes)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return segments.compactMap { segment in
            if let equals = segment.firstIndex(of: "="), equals != segment.startIndex {
                let name = String(segment[..<equals])
                let value = strippingWrappingQuotes(
                    String(segment[segment.index(after: equals)...])
                )
                if !value.isEmpty, name.count <= maxPlausibleNameLength {
                    return Parsed(name: name, value: value)
                }
            }
            // Not a plausible pair. Session tokens are long opaque blobs
            // (JWE: dot-separated base64url, possibly ending in `=` padding —
            // which is why first-`=` splitting above can leave an empty
            // value); a short leftover like `name=` is discarded instead of
            // being sent as a fake credential.
            if segment.count > bareValueMinimumLength || segment.contains(".") {
                return Parsed(name: sessionTokenName, value: segment)
            }
            return nil
        }
    }

    /// The credential check must accept NextAuth's CHUNKED form: a token
    /// exceeding the ~4KB cookie limit ships as `…session-token.0`,
    /// `…session-token.1`, … (numeric suffixes only — the server reassembles
    /// them in order). One chunk alone is half a credential, but presence
    /// detection here is name-based; `verifySession` judges completeness.
    static func isSessionTokenName(_ name: String) -> Bool {
        if name == sessionTokenName { return true }
        guard name.hasPrefix(sessionTokenName + ".") else { return false }
        let suffix = name.dropFirst(sessionTokenName.count + 1)
        return !suffix.isEmpty && suffix.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// Strips exactly ONE pair of symmetric wrapping quotes. Asymmetric or
    /// inner quotes are preserved — `trimmingCharacters` would eat quote
    /// characters that are legitimately part of an RFC 6265 quoted value.
    private static func strippingWrappingQuotes(_ string: String) -> String {
        guard string.count >= 2, string.hasPrefix("\""), string.hasSuffix("\"") else {
            return string
        }
        return String(string.dropFirst().dropLast())
    }

    /// Builds cookies with the attributes the real site uses: scoped to
    /// `.chatgpt.com`, Secure always (the site is HTTPS-only and `__Secure-`
    /// prefixed names REQUIRE it), HttpOnly for `__Secure-` names exactly as
    /// in the wild — `_account` stays page-readable because the SPA reads it
    /// from script for workspace selection.
    static func cookies(from parsed: [Parsed], now: Date) -> [HTTPCookie] {
        parsed.compactMap { pair in
            var properties: [HTTPCookiePropertyKey: Any] = [
                .name: pair.name,
                .value: pair.value,
                .domain: cookieDomain,
                .path: "/",
                .secure: "TRUE",
                .expires: now.addingTimeInterval(validity),
            ]
            if pair.name.hasPrefix("__Secure-") {
                properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE"
            }
            return HTTPCookie(properties: properties)
        }
    }
}
