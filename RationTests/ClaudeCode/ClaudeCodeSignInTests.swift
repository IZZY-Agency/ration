import XCTest
@testable import Ration

final class ClaudeCodeSignInTests: XCTestCase {
    static func signIn(_ id: String, token: String? = nil, savedAt: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> ClaudeCodeSignIn {
        ClaudeCodeSignIn(account: ClaudeCodeConfig.account(from: ClaudeCodeConfigTests.account(id))!,
                         login: ClaudeCodeKeychainEntry.canonical(["refreshToken": token ?? "refresh-\(id)", "accessToken": "access-\(id)"]),
                         savedAt: savedAt)
    }

    func testPayloadRoundTrip() throws {
        let original = Self.signIn("A")
        let decoded = try XCTUnwrap(ClaudeCodeSignIn(payload: original.payload(), uuid: "acc-A"))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.uuid, "acc-A")
    }

    /// Earlier builds stored exactly this shape; the sign-ins they remembered
    /// must carry over.
    func testReadsTheEarlierStoredFormat() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "claudeAiOauth": ["refreshToken": "refresh-A", "accessToken": "access-A"],
            "oauthAccount": ClaudeCodeConfigTests.account("A"),
            "savedAt": 1_790_000_000.0,
        ])
        let decoded = try XCTUnwrap(ClaudeCodeSignIn(payload: payload, uuid: "acc-A"))
        XCTAssertEqual(decoded.account.uuid, "acc-A")
        XCTAssertEqual(decoded.login, Self.signIn("A").login)
        XCTAssertEqual(decoded.savedAt, Date(timeIntervalSince1970: 1_790_000_000))
    }

    func testPayloadWithoutALoginOrAccountIsRejected() throws {
        XCTAssertNil(ClaudeCodeSignIn(payload: try JSONSerialization.data(withJSONObject: ["oauthAccount": ClaudeCodeConfigTests.account("A")]), uuid: "acc-A"))
        XCTAssertNil(ClaudeCodeSignIn(payload: Data("nope".utf8), uuid: "acc-A"))
    }

    /// A payload stored under one uuid but describing another is not trusted.
    func testPayloadForAnotherAccountIsRejected() throws {
        XCTAssertNil(ClaudeCodeSignIn(payload: Self.signIn("B").payload(), uuid: "acc-A"))
    }

    func testInMemoryStoreReplacesByAccount() throws {
        let store = InMemoryClaudeCodeSignInStore([Self.signIn("A")])
        try store.save(Self.signIn("A", token: "refresh-A2"))
        try store.save(Self.signIn("B"))
        XCTAssertEqual(try store.all().map(\.uuid), ["acc-A", "acc-B"])
        XCTAssertEqual(store.signIn("acc-A")?.login, Self.signIn("A", token: "refresh-A2").login)
        try store.delete(accountUUID: "acc-A")
        XCTAssertEqual(try store.all().map(\.uuid), ["acc-B"])
    }
}
