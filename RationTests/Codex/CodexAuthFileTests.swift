import XCTest
@testable import Ration

/// The writer of `~/.codex/auth.json` on real files in a temporary folder
/// (never the real one): in place, through a descriptor whose file was
/// proven to be the user's own 0600 regular file (spec §4.1).
final class CodexAuthFileTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: "CodexAuthFileTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func makeFile(_ name: String = "auth.json", bytes: Data, mode: Int = 0o600) throws -> URL {
        let url = folder.appending(path: name)
        try bytes.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }

    private func inode(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))
        return try XCTUnwrap((attributes[.systemFileNumber] as? NSNumber)?.uint64Value)
    }

    private func assertRefused(_ file: CodexAuthFile, _ expected: CodexAuthFile.Failure, line: UInt = #line) {
        XCTAssertThrowsError(try file.write(Data("new".utf8)), line: line) {
            XCTAssertEqual($0 as? CodexAuthFile.Failure, expected, line: line)
        }
    }

    /// Shorter bytes over longer ones: the old tail must be gone, the inode
    /// kept (Codex and the sandbox exception both name this one file).
    func testWritesInPlaceThroughTheDescriptorAndKeepsTheInode() throws {
        let url = try makeFile(bytes: CodexFixtures.authJSON(refreshToken: String(repeating: "x", count: 400)))
        let before = try inode(url)
        let replacement = CodexFixtures.authJSON(accountID: "acct-B", userID: "user-2")
        try CodexAuthFile(url: url).write(replacement)
        XCTAssertEqual(try Data(contentsOf: url), replacement)
        XCTAssertEqual(try inode(url), before)
        XCTAssertEqual(try CodexAuthFile(url: url).readBytes(), replacement)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testRefusesASymlink() throws {
        let target = try makeFile("real.json", bytes: Data("old".utf8))
        let link = folder.appending(path: "auth.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        assertRefused(CodexAuthFile(url: link), .notARegularFile)
        XCTAssertEqual(try Data(contentsOf: target), Data("old".utf8))
    }

    func testRefusesAFileOthersCanRead() throws {
        let url = try makeFile(bytes: Data("old".utf8), mode: 0o644)
        assertRefused(CodexAuthFile(url: url), .permissive(mode: 0o644))
        XCTAssertEqual(try Data(contentsOf: url), Data("old".utf8))
    }

    func testRefusesADirectory() throws {
        let url = folder.appending(path: "auth.json", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        assertRefused(CodexAuthFile(url: url), .notARegularFile)
    }

    /// Nothing to switch: a switch never creates the file.
    func testAMissingFileIsNeverCreated() throws {
        let url = folder.appending(path: "auth.json")
        assertRefused(CodexAuthFile(url: url), .missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))
        XCTAssertNil(try CodexAuthFile(url: url).readBytes())
        XCTAssertNil(CodexAuthFile(url: url).modificationDate())
    }

    /// A failed sync is its own failure (the bytes may be written
    /// but not durable), retried once when a signal interrupted it.
    func testASyncIsRetriedOnceOnEINTRThenFails() throws {
        var calls = 0
        XCTAssertNoThrow(try CodexAuthFile.sync(3) { _ in calls += 1; if calls == 1 { errno = EINTR; return -1 }; return 0 })
        XCTAssertEqual(calls, 2)

        calls = 0
        XCTAssertThrowsError(try CodexAuthFile.sync(3) { _ in calls += 1; errno = EINTR; return -1 }) {
            XCTAssertEqual($0 as? CodexAuthFile.Failure, .syncFailed)
        }
        XCTAssertEqual(calls, 2, "once more, not forever")

        calls = 0
        XCTAssertThrowsError(try CodexAuthFile.sync(3) { _ in calls += 1; errno = EIO; return -1 }) {
            XCTAssertEqual($0 as? CodexAuthFile.Failure, .syncFailed)
        }
        XCTAssertEqual(calls, 1, "no retry for a real I/O error")

        calls = 0
        XCTAssertNoThrow(try CodexAuthFile.sync(3) { _ in calls += 1; return 0 })
        XCTAssertEqual(calls, 1)
    }

    func testReportsTheModificationDate() throws {
        let url = try makeFile(bytes: Data("{}".utf8))
        XCTAssertNotNil(CodexAuthFile(url: url).modificationDate())
    }

    /// The user's real home, not the sandbox container.
    func testTheUserFileIsInTheRealHome() {
        XCTAssertEqual(CodexAuthFile.userAuthURL, ClaudeCodeConfigFile.userHome.appending(path: ".codex/auth.json"))
    }
}
