import XCTest
@testable import Ration

final class ClaudeCodeConfigTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws { directory = try makeTempDirectory() }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: directory) }

    static func account(_ id: String, fetchedAt: Double = 1_790_695_790_123) -> [String: Any] {
        ["accountUuid": "acc-\(id)", "organizationUuid": "org-\(id)", "organizationName": "\(id)'s Organization",
         "billingType": "stripe_subscription", "profileFetchedAt": fetchedAt, "emailAddress": "\(id)@example.com"]
    }

    static func file(account: [String: Any]?) -> Data {
        var object: [String: Any] = ["numStartups": 5, "theme": "dark", "projects": ["/work/app": ["allowedTools": ["Bash"]]]]
        if let account { object["oauthAccount"] = account }
        return try! JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    }

    func testReadsTheAccountSection() throws {
        let account = try XCTUnwrap(try ClaudeCodeConfig.account(in: Self.file(account: Self.account("A"))))
        XCTAssertEqual(account.uuid, "acc-A")
        XCTAssertEqual(account.organizationUUID, "org-A")
        XCTAssertEqual(account.organizationName, "A's Organization")
        XCTAssertEqual(account.billingType, "stripe_subscription")
        XCTAssertEqual(account.profileFetchedAt, 1_790_695_790_123)
        XCTAssertEqual(account.json, ClaudeCodeKeychainEntry.canonical(Self.account("A")))
    }

    func testNoAccountSectionOrNoUuidIsNil() throws {
        XCTAssertNil(try ClaudeCodeConfig.account(in: Self.file(account: nil)))
        XCTAssertNil(try ClaudeCodeConfig.account(in: Self.file(account: ["organizationUuid": "org-A"])))
    }

    func testNotJSONThrows() {
        XCTAssertThrowsError(try ClaudeCodeConfig.account(in: Data("{\"half".utf8))) {
            XCTAssertEqual($0 as? ClaudeCodeConfig.Failure, .notJSON)
        }
    }

    /// Spec §4.1: only `oauthAccount` changes; every other key is kept.
    func testReplacingTheAccountKeepsEveryOtherKey() throws {
        let replaced = try ClaudeCodeConfig.replacingAccount(in: Self.file(account: Self.account("A")),
                                                            with: ClaudeCodeKeychainEntry.canonical(Self.account("B")))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: replaced) as? [String: Any])
        XCTAssertEqual(object["numStartups"] as? Int, 5)
        XCTAssertEqual(object["theme"] as? String, "dark")
        XCTAssertEqual(ClaudeCodeKeychainEntry.canonical(object["projects"]!),
                       ClaudeCodeKeychainEntry.canonical(["/work/app": ["allowedTools": ["Bash"]]]))
        XCTAssertEqual(try ClaudeCodeConfig.account(in: replaced)?.uuid, "acc-B")
    }

    /// The sandbox allows this one path, not a file beside it: the write is in place.
    func testWriteKeepsTheSameFile() throws {
        let url = directory.appending(path: ".claude.json")
        try Self.file(account: Self.account("A")).write(to: url)
        let file = ClaudeCodeConfigFile(url: url)
        let before = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.systemFileNumber] as? Int
        let bytes = Self.file(account: Self.account("B"))
        try file.write(bytes)
        let after = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.systemFileNumber] as? Int
        XCTAssertEqual(before, after)
        XCTAssertEqual(try file.readBytes(), bytes)
        XCTAssertNotNil(file.modificationDate())
    }

    func testMissingFileReadsNil() throws {
        XCTAssertNil(try ClaudeCodeConfigFile(url: directory.appending(path: "absent.json")).readBytes())
    }

    func testJournalRoundTripAndClear() throws {
        let store = ClaudeCodeJournalFile(url: directory.appending(path: "claude-code-switch-journal.json"))
        XCTAssertNil(store.read())
        let journal = ClaudeCodeSwitchJournal(startedAt: Date(timeIntervalSince1970: 1_790_000_000), from: "acc-A", to: "acc-B",
                                              config: Self.file(account: Self.account("A")))
        try store.write(journal)
        XCTAssertEqual(store.read(), journal)
        try store.clear()
        XCTAssertNil(store.read())
        try store.clear()
    }

    func testUnreadableJournalIsNil() throws {
        let url = directory.appending(path: "claude-code-switch-journal.json")
        try Data("garbage".utf8).write(to: url)
        XCTAssertNil(ClaudeCodeJournalFile(url: url).read())
    }
}
