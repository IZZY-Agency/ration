import XCTest
@testable import Ration

/// A remembered Codex login and its Keychain payload (spec §4.2).
final class CodexSignInTests: XCTestCase {
    static let savedAt = Date(timeIntervalSince1970: 1_790_000_000)

    static func signIn(_ account: String = "acct-A", user: String = "user-1", refreshToken: String? = nil,
                       lastRefresh: String = "2026-10-11T18:00:00.000000Z", savedAt: Date = savedAt) -> CodexSignIn {
        CodexSignIn(login: CodexFixtures.login(CodexFixtures.authJSON(accountID: account, userID: user, email: "\(user)@example.com",
                                                                     lastRefresh: lastRefresh,
                                                                     refreshToken: refreshToken ?? "rt-\(account)-\(user)")),
                    savedAt: savedAt)
    }

    /// The copy is the file's exact bytes (spec §4.2 `{auth: <file bytes>, savedAt}`):
    /// a switch writes back what Codex wrote, byte for byte.
    func testPayloadRoundTripKeepsTheExactFileBytes() throws {
        let original = Self.signIn()
        let decoded = try XCTUnwrap(CodexSignIn(payload: original.payload(), id: "acct-A|user-1"))
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.login.bytes, CodexFixtures.authJSON(accountID: "acct-A", userID: "user-1", email: "user-1@example.com",
                                                                   refreshToken: "rt-acct-A-user-1"))
        XCTAssertEqual(decoded.id, "acct-A|user-1")
        XCTAssertEqual(decoded.login.lastRefresh, "2026-10-11T18:00:00.000000Z")
    }

    /// The journal names a copy by its `savedAt` and keeps ISO 8601 seconds:
    /// a copy's time is whole seconds, so the two always compare equal.
    func testSavedAtIsKeptInWholeSeconds() throws {
        let signIn = Self.signIn(savedAt: Date(timeIntervalSince1970: 1_790_000_000.75))
        XCTAssertEqual(signIn.savedAt, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(CodexSignIn(payload: signIn.payload(), id: signIn.id)?.savedAt, Date(timeIntervalSince1970: 1_790_000_000))
    }

    /// Two seats of one workspace are two items: a payload must match both
    /// parts of the key it is stored under.
    func testAPayloadForAnotherSeatIsRejected() {
        XCTAssertNil(CodexSignIn(payload: Self.signIn(user: "user-2").payload(), id: "acct-A|user-1"))
        XCTAssertNil(CodexSignIn(payload: Self.signIn("acct-B").payload(), id: "acct-A|user-1"))
    }

    func testAPayloadWithoutAWholeLoginIsRejected() throws {
        XCTAssertNil(CodexSignIn(payload: Data("nope".utf8), id: "acct-A|user-1"))
        XCTAssertNil(CodexSignIn(payload: try JSONSerialization.data(withJSONObject: ["savedAt": 1_790_000_000]), id: "acct-A|user-1"))
        XCTAssertNil(CodexSignIn(payload: try JSONSerialization.data(withJSONObject: ["auth": "%%%", "savedAt": 1_790_000_000]),
                                 id: "acct-A|user-1"))
        let mixed = CodexFixtures.file(idToken: CodexFixtures.idToken(CodexFixtures.claims(accountID: "acct-A", userID: "user-1")),
                                       tokensAccountID: "acct-B")
        XCTAssertNil(CodexSignIn(payload: try JSONSerialization.data(withJSONObject: ["auth": mixed.base64EncodedString(), "savedAt": 1]),
                                 id: "acct-A|user-1"), "a damaged file is never a remembered copy")
        let noTime = try JSONSerialization.data(withJSONObject: ["auth": CodexFixtures.authJSON().base64EncodedString()])
        XCTAssertNil(CodexSignIn(payload: noTime, id: "acct-A|user-1"))
    }

    func testOneUserInTwoWorkspacesIsTwoItems() throws {
        let store = InMemoryCodexSignInStore([Self.signIn("acct-A"), Self.signIn("acct-B")])
        XCTAssertEqual(try store.all().map(\.id), ["acct-A|user-1", "acct-B|user-1"])
    }

    func testInMemoryStoreReplacesByLoginID() throws {
        let store = InMemoryCodexSignInStore([Self.signIn()])
        try store.save(Self.signIn(refreshToken: "rt-newer"))
        try store.save(Self.signIn(user: "user-2"))
        XCTAssertEqual(try store.all().map(\.id), ["acct-A|user-1", "acct-A|user-2"])
        XCTAssertEqual(store.items["acct-A|user-1"], Self.signIn(refreshToken: "rt-newer"))
        try store.delete(id: "acct-A|user-1")
        XCTAssertEqual(try store.all().map(\.id), ["acct-A|user-2"])
    }

    /// An item that cannot be read fails the listing (it is never
    /// silently left out), and deleteAll removes every item, read or not.
    func testInMemoryStoreUnreadableItemsAndDeleteAll() throws {
        let store = InMemoryCodexSignInStore([Self.signIn(), Self.signIn(user: "user-2")])
        store.unreadableIDs = ["acct-A|user-2"]
        XCTAssertThrowsError(try store.all())
        try store.deleteAll()
        XCTAssertEqual(try store.all(), [])
        XCTAssertTrue(store.items.isEmpty)
    }

    func testInMemoryStoreFailures() {
        let store = InMemoryCodexSignInStore([Self.signIn()])
        store.saveFails = true
        store.deleteFails = true
        XCTAssertThrowsError(try store.save(Self.signIn(user: "user-2")))
        XCTAssertThrowsError(try store.delete(id: "acct-A|user-1"))
        XCTAssertEqual(store.items.keys.sorted(), ["acct-A|user-1"])
    }
}
