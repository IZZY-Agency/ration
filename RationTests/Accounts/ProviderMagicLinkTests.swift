import XCTest
@testable import Ration

final class ProviderMagicLinkTests: XCTestCase {
    func testClaudeAcceptsExactHTTPSClaudeHost() {
        XCTAssertEqual(
            ProviderMagicLink.url(
                from: "  https://claude.ai/magic-link?token=secret  ",
                provider: .claude
            ),
            URL(string: "https://claude.ai/magic-link?token=secret")
        )
    }

    func testClaudeRejectsInsecureLookalikeAndOtherProviderLinks() {
        XCTAssertNil(
            ProviderMagicLink.url(
                from: "http://claude.ai/login?token=secret",
                provider: .claude
            )
        )
        XCTAssertNil(
            ProviderMagicLink.url(
                from: "https://claude.ai.evil.example/login",
                provider: .claude
            )
        )
        XCTAssertNil(
            ProviderMagicLink.url(
                from: "https://chatgpt.com/auth",
                provider: .claude
            )
        )
        XCTAssertNil(
            ProviderMagicLink.url(
                from: "https://auth.claude.ai/magic-link",
                provider: .claude
            )
        )
        XCTAssertNil(
            ProviderMagicLink.url(
                from: "https://click.mail.anthropic.com/redirect",
                provider: .claude
            )
        )
    }

    func testOpenPassesValidatedRequestToExistingBrowserLoader() throws {
        var loadedRequest: URLRequest?

        let didOpen = ProviderMagicLink.open(
            input: "https://claude.ai/magic-link?token=secret",
            provider: .claude,
            load: { loadedRequest = $0 }
        )

        XCTAssertTrue(didOpen)
        XCTAssertEqual(
            try XCTUnwrap(loadedRequest?.url),
            URL(string: "https://claude.ai/magic-link?token=secret")
        )
    }
}
