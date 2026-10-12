import XCTest
@testable import Ration

/// The login in `~/.codex/auth.json` and who it signs in (spec §4.1).
final class CodexLoginTests: XCTestCase {
    private typealias Failure = CodexLogin.Failure

    private func assertThrows(_ bytes: Data, _ expected: Failure, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try CodexLogin(fileBytes: bytes), file: file, line: line) {
            XCTAssertEqual($0 as? Failure, expected, file: file, line: line)
        }
    }

    func testDecodesIdentityFromTheIdToken() throws {
        let bytes = CodexFixtures.authJSON(accountID: "acct-B", userID: "user-2", email: "personal@example.com", planType: "pro",
                                           lastRefresh: "2026-10-11T18:00:00.123456Z")
        let login = try CodexLogin(fileBytes: bytes)
        XCTAssertEqual(login.accountID, "acct-B")
        XCTAssertEqual(login.userID, "user-2")
        XCTAssertEqual(login.email, "personal@example.com")
        XCTAssertEqual(login.planType, "pro")
        XCTAssertEqual(login.lastRefresh, "2026-10-11T18:00:00.123456Z")
        XCTAssertEqual(login.bytes, bytes, "the file's bytes as read: a switch writes them back unchanged")
    }

    func testFallsBackToTokensAccountIDAndUserID() throws {
        var claims = CodexFixtures.claims(accountID: nil, userID: nil)
        claims[CodexFixtures.authClaim] = nil
        claims["user_id"] = "user-top"
        let login = try CodexLogin(fileBytes: CodexFixtures.file(idToken: CodexFixtures.idToken(claims), tokensAccountID: "acct-T"))
        XCTAssertEqual(login.accountID, "acct-T")
        XCTAssertEqual(login.userID, "user-top")
        XCTAssertNil(login.planType)
    }

    /// Codex's own fallback (`token_data.rs`): `user_id` inside the auth claim.
    func testReadsTheAuthClaimsUserIDWhenChatGPTUserIDIsMissing() throws {
        var claims = CodexFixtures.claims(accountID: "acct-A", userID: nil)
        claims[CodexFixtures.authClaim] = ["chatgpt_account_id": "acct-A", "user_id": "user-9"]
        claims["email"] = nil
        claims["https://api.openai.com/profile"] = ["email": "profile@example.com"]
        let login = try CodexLogin(fileBytes: CodexFixtures.file(idToken: CodexFixtures.idToken(claims), tokensAccountID: "acct-A"))
        XCTAssertEqual(login.userID, "user-9")
        XCTAssertEqual(login.email, "profile@example.com")
    }

    func testAnAPIKeyLoginIsUnsupported() {
        assertThrows(CodexFixtures.apiKeyJSON(), .unsupported)
        assertThrows(Data(#"{"auth_mode":"chatgpt","tokens":null}"#.utf8), .unsupported)
        assertThrows(Data(#"{"auth_mode":"chatgpt"}"#.utf8), .unsupported)
        assertThrows(Data("{}".utf8), .unsupported)
    }

    /// Files written before Codex recorded `auth_mode`: Codex reads tokens
    /// without an API key as a ChatGPT login, and so does Ration.
    func testAFileWithoutAnAuthModeIsReadAsCodexReadsIt() throws {
        let token = CodexFixtures.idToken(CodexFixtures.claims(accountID: "acct-A", userID: "user-1"))
        XCTAssertEqual(try CodexLogin(fileBytes: CodexFixtures.file(idToken: token, tokensAccountID: "acct-A", authMode: nil)).id,
                       "acct-A|user-1")
        let withKey = Data(#"{"OPENAI_API_KEY":"sk-test","tokens":{"id_token":"\#(token)","access_token":"a","refresh_token":"r"}}"#.utf8)
        assertThrows(withKey, .unsupported)
    }

    func testGarbageIsUnreadable() {
        assertThrows(Data("{not json".utf8), .unreadable)
        assertThrows(Data(), .unreadable)
        assertThrows(CodexFixtures.authJSON().prefix(60), .unreadable)
        assertThrows(CodexFixtures.file(idToken: "header.%%%not-base64%%%.sig", tokensAccountID: "acct-A"), .unreadable)
        assertThrows(CodexFixtures.file(idToken: "not-a-jwt", tokensAccountID: "acct-A"), .unreadable)
    }

    /// The mixed file of spec §2: Ration's new account id beside the old
    /// account's refreshed tokens.
    func testAMixedFileIsDamaged() {
        let tokenA = CodexFixtures.idToken(CodexFixtures.claims(accountID: "acct-A", userID: "user-1"))
        assertThrows(CodexFixtures.file(idToken: tokenA, tokensAccountID: "acct-B"), .damaged)
        let noUser = CodexFixtures.idToken(CodexFixtures.claims(accountID: "acct-A", userID: nil))
        assertThrows(CodexFixtures.file(idToken: noUser, tokensAccountID: "acct-A"), .damaged)
        let noAccount = CodexFixtures.idToken(CodexFixtures.claims(accountID: nil, userID: "user-1"))
        assertThrows(CodexFixtures.file(idToken: noAccount, tokensAccountID: nil), .damaged)
    }

    func testTheLoginIDIsTheAccountAndUserPair() throws {
        XCTAssertEqual(try CodexLogin(fileBytes: CodexFixtures.authJSON()).id, "acct-A|user-1")
        let seat1 = try CodexLogin(fileBytes: CodexFixtures.authJSON(accountID: "acct-X", userID: "user-1"))
        let seat2 = try CodexLogin(fileBytes: CodexFixtures.authJSON(accountID: "acct-X", userID: "user-2"))
        XCTAssertNotEqual(seat1.id, seat2.id, "two seats of one workspace are two logins")
    }
}
