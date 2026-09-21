import WebKit
import XCTest
@testable import Ration

final class SignInNavigationPolicyTests: XCTestCase {
    func testExternalOpenRequiresMainFrameUserClick() {
        // Only a user-initiated main-frame click may launch another app.
        XCTAssertTrue(
            SignInNavigationPolicy.mayOpenExternally(
                navigationType: .linkActivated, isMainFrame: true
            )
        )
        // Script-initiated (.other) navigation must not.
        XCTAssertFalse(
            SignInNavigationPolicy.mayOpenExternally(
                navigationType: .other, isMainFrame: true
            )
        )
        // A click inside a subframe must not.
        XCTAssertFalse(
            SignInNavigationPolicy.mayOpenExternally(
                navigationType: .linkActivated, isMainFrame: false
            )
        )
        // A new-window target (targetFrame == nil) must NOT be treated as the
        // main frame — otherwise a `_blank` link could launch another app.
        XCTAssertFalse(
            SignInNavigationPolicy.mayOpenExternally(
                navigationType: .linkActivated, isMainFrame: nil
            )
        )
    }

    func testHTTPSAndAboutAreAllowed() {
        // HTTPS (including cross-origin SSO) and about:blank must load in-view,
        // so legitimate Google/Microsoft/Apple/Auth0 redirects never break.
        XCTAssertEqual(
            SignInNavigationPolicy.decision(for: URL(string: "https://claude.ai/login")),
            .allow
        )
        XCTAssertEqual(
            SignInNavigationPolicy.decision(for: URL(string: "https://accounts.google.com/o/oauth2/auth")),
            .allow
        )
        XCTAssertEqual(
            SignInNavigationPolicy.decision(for: URL(string: "about:blank")),
            .allow
        )
    }

    func testContactSchemesOpenExternally() {
        XCTAssertEqual(
            SignInNavigationPolicy.decision(for: URL(string: "mailto:support@openai.com")),
            .openExternally
        )
        XCTAssertEqual(
            SignInNavigationPolicy.decision(for: URL(string: "tel:+15551234567")),
            .openExternally
        )
    }

    func testInsecureAndAppSchemesAreCancelled() {
        // Never downgrade an auth view to plaintext HTTP...
        XCTAssertEqual(
            SignInNavigationPolicy.decision(for: URL(string: "http://claude.ai/login")),
            .cancel
        )
        // ...nor let a page deep-link into another app or a local resource.
        XCTAssertEqual(
            SignInNavigationPolicy.decision(for: URL(string: "myapp://open?token=x")),
            .cancel
        )
        XCTAssertEqual(
            SignInNavigationPolicy.decision(for: URL(string: "file:///etc/passwd")),
            .cancel
        )
        XCTAssertEqual(SignInNavigationPolicy.decision(for: nil), .cancel)
    }
}
