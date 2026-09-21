import WebKit
import XCTest
@testable import Ration

/// Passkey-only OpenAI accounts cannot complete WebAuthn inside a WKWebView
/// (Apple gates it behind the restricted web-browser public-key-credential
/// entitlement), so the sign-in window accepts a pasted session cookie from
/// the user's real browser instead. The parser is deliberately forgiving
/// about paste shapes — `verifySession` remains the authority on whether the
/// pasted session actually works.
final class ChatGPTSessionCookiePasteTests: XCTestCase {
    private let tokenName = "__Secure-next-auth.session-token"
    // Shaped like a real NextAuth JWE: dot-separated base64url segments,
    // trailing padding included to prove first-`=`-split safety. NOT a real
    // credential.
    private let jweValue = "eyJhbGciOiJkaXIiLCJlbmMiOiJBMjU2R0NNIn0..fake.payload.tag="

    func testBareValuePairsWithTheSessionTokenName() {
        let parsed = ChatGPTSessionCookiePaste.parse(jweValue)
        XCTAssertEqual(parsed, [.init(name: tokenName, value: jweValue)])
    }

    func testExplicitNameValuePair() {
        let parsed = ChatGPTSessionCookiePaste.parse("\(tokenName)=\(jweValue)")
        XCTAssertEqual(parsed, [.init(name: tokenName, value: jweValue)])
    }

    func testValueContainingEqualsSplitsOnFirstEqualsOnly() {
        let parsed = ChatGPTSessionCookiePaste.parse("_account=abc=def")
        XCTAssertEqual(parsed, [.init(name: "_account", value: "abc=def")])
    }

    func testCookieHeaderPasteYieldsAllPairs() {
        let parsed = ChatGPTSessionCookiePaste.parse(
            "Cookie: \(tokenName)=\(jweValue); _account=personal"
        )
        XCTAssertEqual(parsed, [
            .init(name: tokenName, value: jweValue),
            .init(name: "_account", value: "personal"),
        ])
    }

    func testWhitespaceQuotesAndNewlinesAreTolerated() {
        let parsed = ChatGPTSessionCookiePaste.parse(
            "  \"\(tokenName)=\(jweValue)\" \n _account=personal \n"
        )
        XCTAssertEqual(parsed, [
            .init(name: tokenName, value: jweValue),
            .init(name: "_account", value: "personal"),
        ])
    }

    /// A bare JWE whose first segment ends in base64 padding must NOT be
    /// mis-split into (giant-name, "="): an implausible name (over-long)
    /// demotes the whole segment to a bare value.
    func testOverlongNameCandidateIsTreatedAsBareValue() {
        let longLeft = String(repeating: "a", count: 200)
        let raw = "\(longLeft)=="
        let parsed = ChatGPTSessionCookiePaste.parse(raw)
        XCTAssertEqual(parsed, [.init(name: tokenName, value: raw)])
    }

    /// NextAuth CHUNKS a session token that exceeds the ~4KB cookie limit
    /// into `…session-token.0`, `…session-token.1`, … — a real browser
    /// session (richer claims than the app's own) routinely ships chunked.
    /// Both chunk pairs must parse, and the chunked names must satisfy the
    /// credential-presence check (one chunk alone is half a credential —
    /// `verifySession` remains the judge of completeness).
    func testChunkedSessionTokenPairsParseAndCountAsCredential() {
        let parsed = ChatGPTSessionCookiePaste.parse(
            "\(tokenName).0=chunk0.of.jwe; \(tokenName).1=chunk1.of.jwe"
        )
        XCTAssertEqual(parsed, [
            .init(name: "\(tokenName).0", value: "chunk0.of.jwe"),
            .init(name: "\(tokenName).1", value: "chunk1.of.jwe"),
        ])
        XCTAssertTrue(parsed.allSatisfy { ChatGPTSessionCookiePaste.isSessionTokenName($0.name) })
    }

    func testSessionTokenNameRecognitionIsExactOrNumericChunk() {
        XCTAssertTrue(ChatGPTSessionCookiePaste.isSessionTokenName(tokenName))
        XCTAssertTrue(ChatGPTSessionCookiePaste.isSessionTokenName("\(tokenName).0"))
        XCTAssertTrue(ChatGPTSessionCookiePaste.isSessionTokenName("\(tokenName).12"))
        XCTAssertFalse(ChatGPTSessionCookiePaste.isSessionTokenName("\(tokenName).x"))
        XCTAssertFalse(ChatGPTSessionCookiePaste.isSessionTokenName("\(tokenName)."))
        XCTAssertFalse(ChatGPTSessionCookiePaste.isSessionTokenName("__Secure-next-auth.callback-url"))
    }

    /// The masked single-line field flattens a multi-line paste into spaces.
    /// Cookie names and values can never CONTAIN spaces (RFC 6265), so
    /// whitespace is a safe pair separator.
    func testSpaceSeparatedPairsParse() {
        let parsed = ChatGPTSessionCookiePaste.parse(
            "\(tokenName).0=chunk0 \(tokenName).1=chunk1"
        )
        XCTAssertEqual(parsed, [
            .init(name: "\(tokenName).0", value: "chunk0"),
            .init(name: "\(tokenName).1", value: "chunk1"),
        ])
    }

    /// Quote handling per RFC 6265: exactly one pair of SYMMETRIC wrapping
    /// quotes is stripped from a value; asymmetric or inner quotes are part
    /// of the value and must survive.
    func testQuotedValuesAreUnwrappedOnceAndInnerQuotesSurvive() {
        XCTAssertEqual(
            ChatGPTSessionCookiePaste.parse("_account=\"personal\""),
            [.init(name: "_account", value: "personal")]
        )
        XCTAssertEqual(
            ChatGPTSessionCookiePaste.parse("_account=\"per\"sonal\""),
            [.init(name: "_account", value: "per\"sonal")]
        )
        XCTAssertEqual(
            ChatGPTSessionCookiePaste.parse("_account=personal\""),
            [.init(name: "_account", value: "personal\"")],
            "an asymmetric trailing quote is data, not wrapping"
        )
    }

    func testEmptyAndSeparatorOnlyInputParseToNothing() {
        XCTAssertEqual(ChatGPTSessionCookiePaste.parse(""), [])
        XCTAssertEqual(ChatGPTSessionCookiePaste.parse("  ;\n; "), [])
        XCTAssertEqual(ChatGPTSessionCookiePaste.parse("name="), [], "empty value is not a cookie")
    }

    func testCookiesCarrySafeChatGPTAttributes() throws {
        let now = Date(timeIntervalSince1970: 1_786_000_000)
        let cookies = ChatGPTSessionCookiePaste.cookies(
            from: ChatGPTSessionCookiePaste.parse(
                "\(tokenName)=\(jweValue); _account=personal"
            ),
            now: now
        )
        XCTAssertEqual(cookies.count, 2)

        let token = try XCTUnwrap(cookies.first { $0.name == tokenName })
        XCTAssertEqual(token.domain, ".chatgpt.com")
        XCTAssertEqual(token.path, "/")
        XCTAssertTrue(token.isSecure, "__Secure- prefixed cookies require Secure")
        XCTAssertTrue(
            token.isHTTPOnly,
            "the session token is HttpOnly in the wild; the real-store round-trip test proves WKHTTPCookieStore accepts it"
        )
        let expires = try XCTUnwrap(token.expiresDate)
        XCTAssertEqual(
            expires.timeIntervalSince(now), 90 * 24 * 3600, accuracy: 1,
            "must comfortably outlive the server-side session validity"
        )

        let account = try XCTUnwrap(cookies.first { $0.name == "_account" })
        XCTAssertTrue(account.isSecure)
        XCTAssertFalse(account.isHTTPOnly)
    }

    /// Production-shaped round trip: an IDENTIFIED data store (what
    /// `WebProfileManager` builds per account) is canonical by identifier, so
    /// the `webView.configuration.websiteDataStore` access path the model
    /// uses — which returns a configuration COPY — still reaches the same
    /// store. (Ephemeral stores do NOT behave this way; see the spy comment
    /// in AppModelTests.)
    @MainActor
    func testCookiesReachAnIdentifiedStoreThroughTheAttachedWebViewConfiguration() async throws {
        let identifier = UUID()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: identifier)
        let webView = WKWebView(frame: .zero, configuration: configuration)
        defer {
            // Best-effort cleanup of the on-disk store once the view is gone.
            Task { try? await WKWebsiteDataStore.remove(forIdentifier: identifier) }
        }
        let cookies = ChatGPTSessionCookiePaste.cookies(
            from: ChatGPTSessionCookiePaste.parse("\(tokenName)=\(jweValue)"),
            now: .now
        )

        // Write through one configuration copy…
        let writeStore = webView.configuration.websiteDataStore.httpCookieStore
        for cookie in cookies {
            await writeStore.setCookie(cookie)
        }

        // …read through another: identified stores must converge.
        let read = await webView.configuration.websiteDataStore
            .httpCookieStore.allCookies()
        XCTAssertEqual(read.map(\.name), [tokenName])
        XCTAssertEqual(read.first?.domain, ".chatgpt.com")
    }

    /// Real-store round trip: applying the built cookies to a WKHTTPCookieStore
    /// must land them retrievably (this is the exact store the sign-in web
    /// view's fetches read from).
    @MainActor
    func testAppliedCookiesLandInTheCookieStore() async {
        // The data store must be RETAINED for the cookie store to function —
        // grabbing `.httpCookieStore` off a temporary silently no-ops.
        let dataStore = WKWebsiteDataStore.nonPersistent()
        let store = dataStore.httpCookieStore
        let cookies = ChatGPTSessionCookiePaste.cookies(
            from: ChatGPTSessionCookiePaste.parse("\(tokenName)=\(jweValue)"),
            now: .now
        )

        for cookie in cookies {
            await store.setCookie(cookie)
        }

        let stored = await store.allCookies()
        XCTAssertEqual(stored.map(\.name), ["__Secure-next-auth.session-token"])
        XCTAssertEqual(stored.first?.domain, ".chatgpt.com")
    }
}
