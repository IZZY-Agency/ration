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

    /// Shorter bytes over longer ones leave no old tail.
    func testWriteTruncatesTheOldBytes() throws {
        let url = directory.appending(path: ".claude.json")
        try Data(repeating: UInt8(ascii: "x"), count: 4_000).write(to: url)
        let bytes = Self.file(account: nil)
        try ClaudeCodeConfigFile(url: url).write(bytes)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
    }

    /// A symlink is refused before a byte changes: the file behind it is not
    /// the one the user's Claude Code reads by name.
    func testWriteRefusesASymlink() throws {
        let target = directory.appending(path: "real.json")
        try Data("old".utf8).write(to: target)
        let link = directory.appending(path: ".claude.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try ClaudeCodeConfigFile(url: link).write(Data("new".utf8))) {
            XCTAssertEqual($0 as? InPlaceFileWrite.Failure, .notARegularFile)
        }
        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
    }

    func testWriteRefusesADirectory() throws {
        let url = directory.appending(path: ".claude.json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try ClaudeCodeConfigFile(url: url).write(Data("new".utf8))) {
            XCTAssertEqual($0 as? InPlaceFileWrite.Failure, .notARegularFile)
        }
    }

    /// A switch never creates the file.
    func testWriteNeverCreatesAMissingFile() throws {
        let url = directory.appending(path: ".claude.json")
        XCTAssertThrowsError(try ClaudeCodeConfigFile(url: url).write(Data("new".utf8))) {
            XCTAssertEqual($0 as? InPlaceFileWrite.Failure, .missing)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
    }

    /// The check a switch asks before it changes the login: the refusals of
    /// a write, and no change to the file.
    func testCheckWritableRefusesWhatAWriteWouldAndChangesNothing() throws {
        let url = directory.appending(path: ".claude.json")
        XCTAssertThrowsError(try ClaudeCodeConfigFile(url: url).checkWritable()) {
            XCTAssertEqual($0 as? InPlaceFileWrite.Failure, .missing)
        }
        let target = directory.appending(path: "real.json")
        try Data("old".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        XCTAssertThrowsError(try ClaudeCodeConfigFile(url: url).checkWritable()) {
            XCTAssertEqual($0 as? InPlaceFileWrite.Failure, .notARegularFile)
        }
        XCTAssertNoThrow(try ClaudeCodeConfigFile(url: target).checkWritable())
        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8), "a check never truncates")
    }

    /// A file the user can write but not read is refused untouched: a
    /// recovery that could not read it must not replace it with older bytes.
    func testWriteRefusesAFileItCannotReadBack() throws {
        let url = directory.appending(path: ".claude.json")
        try Data("newer settings".utf8).write(to: url)
        let path = url.path(percentEncoded: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o200], ofItemAtPath: path)
        XCTAssertThrowsError(try ClaudeCodeConfigFile(url: url).checkWritable())
        XCTAssertThrowsError(try ClaudeCodeConfigFile(url: url).write(Data("old".utf8)))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        XCTAssertEqual(try Data(contentsOf: url), Data("newer settings".utf8))
    }

    /// No secret in this file, so no mode is required of it (Codex's login
    /// file must be 0600): Claude Code's own 0644 file is written.
    func testWriteAcceptsAFileOthersCanRead() throws {
        let url = directory.appending(path: ".claude.json")
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path(percentEncoded: false))
        try ClaudeCodeConfigFile(url: url).write(Data("new".utf8))
        XCTAssertEqual(try Data(contentsOf: url), Data("new".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o644)
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
