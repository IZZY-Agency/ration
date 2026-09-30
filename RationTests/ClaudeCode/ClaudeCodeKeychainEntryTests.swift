import XCTest
@testable import Ration

final class ClaudeCodeKeychainEntryTests: XCTestCase {
    private func entryItem(login: String = "refresh-A", mcp: String = "m1") -> [String: Any] {
        ["claudeAiOauth": ["refreshToken": login, "accessToken": "access-\(login)"],
         "mcpOAuth": ["server": ["token": mcp]]]
    }

    private func loginData(_ token: String) -> Data {
        ClaudeCodeKeychainEntry.canonical(["refreshToken": token, "accessToken": "access-\(token)"])
    }

    private func entry(_ tool: FakeSecurityTool) -> ClaudeCodeKeychainEntry {
        ClaudeCodeKeychainEntry(tool: tool, user: "me")
    }

    func testReadsTheEntryAndItsLogin() throws {
        let tool = FakeSecurityTool(item: entryItem())
        XCTAssertEqual(Set(try entry(tool).readObject().keys), ["claudeAiOauth", "mcpOAuth"])
        XCTAssertEqual(try entry(tool).login(), loginData("refresh-A"))
        XCTAssertEqual(tool.calls.first?.arguments, ["find-generic-password", "-a", "me", "-w", "-s", "Claude Code-credentials"])
    }

    func testMissingEntryAndMissingLogin() {
        XCTAssertThrowsError(try entry(FakeSecurityTool()).readObject()) { XCTAssertEqual($0 as? ClaudeCodeKeychainEntry.Failure, .notFound) }
        XCTAssertThrowsError(try entry(FakeSecurityTool(item: ["mcpOAuth": [:] as [String: Any]])).login()) {
            XCTAssertEqual($0 as? ClaudeCodeKeychainEntry.Failure, .noLogin)
        }
    }

    /// Spec §4.1: only `claudeAiOauth` changes; MCP sign-ins stay as they were.
    func testReplacingTheLoginKeepsEverythingElse() throws {
        let tool = FakeSecurityTool(item: entryItem())
        try entry(tool).replaceLogin(with: loginData("refresh-B"))
        let item = try XCTUnwrap(tool.item)
        XCTAssertEqual(ClaudeCodeKeychainEntry.canonical(item["mcpOAuth"]!), ClaudeCodeKeychainEntry.canonical(["server": ["token": "m1"]]))
        XCTAssertEqual(ClaudeCodeKeychainEntry.canonical(item["claudeAiOauth"]!), loginData("refresh-B"))
    }

    /// Claude Code's own rule: stdin up to 4,032 characters, the command line above.
    func testSmallEntryGoesThroughStdinALargeOneOnTheCommandLine() throws {
        let small = FakeSecurityTool(item: entryItem())
        try entry(small).replaceLogin(with: loginData("refresh-B"))
        let smallWrite = try XCTUnwrap(small.calls.first { $0.arguments.first != "find-generic-password" })
        XCTAssertEqual(smallWrite, .init(arguments: ["-i"], usedStdin: true))

        let large = FakeSecurityTool(item: entryItem(mcp: String(repeating: "x", count: 3_000)))
        try entry(large).replaceLogin(with: loginData("refresh-B"))
        let largeWrite = try XCTUnwrap(large.calls.first { $0.arguments.first != "find-generic-password" })
        XCTAssertFalse(largeWrite.usedStdin)
        XCTAssertEqual(Array(largeWrite.arguments.prefix(7)), ["add-generic-password", "-U", "-a", "me", "-s", "Claude Code-credentials", "-X"])
        XCTAssertEqual(ClaudeCodeKeychainEntry.canonical(large.item!["claudeAiOauth"]!), loginData("refresh-B"))
    }

    /// Claude Code wrote between Ration's two reads → nothing written.
    func testAChangeBetweenTheReadsIsAConflictAndNothingIsWritten() {
        let tool = FakeSecurityTool(item: entryItem())
        tool.afterRead = { count, item in
            if count == 1 { item = try! JSONSerialization.data(withJSONObject: self.entryItem(mcp: "m2")) }
        }
        XCTAssertThrowsError(try entry(tool).replaceLogin(with: loginData("refresh-B"))) {
            XCTAssertEqual($0 as? ClaudeCodeKeychainEntry.Failure, .changedBeforeWrite)
        }
        XCTAssertEqual(tool.writes, 0)
    }

    /// Claude Code wrote right after Ration → reported.
    func testAChangeRightAfterTheWriteIsAConflict() {
        let tool = FakeSecurityTool(item: entryItem())
        tool.afterWrite = { item in item = try! JSONSerialization.data(withJSONObject: self.entryItem(login: "refresh-B", mcp: "m9")) }
        XCTAssertThrowsError(try entry(tool).replaceLogin(with: loginData("refresh-B"))) {
            XCTAssertEqual($0 as? ClaudeCodeKeychainEntry.Failure, .conflict)
        }
    }

    func testAFailedWriteReportsItsStatus() {
        let tool = FakeSecurityTool(item: entryItem())
        tool.failWriteStatus = 45
        XCTAssertThrowsError(try entry(tool).replaceLogin(with: loginData("refresh-B"))) {
            XCTAssertEqual($0 as? ClaudeCodeKeychainEntry.Failure, .writeFailed(45))
        }
    }

    /// Rollback must be able to put the old login back even while the entry moves.
    func testRestoringALoginSkipsTheConflictCheck() throws {
        let tool = FakeSecurityTool(item: entryItem(login: "refresh-B"))
        tool.afterRead = { count, item in
            if count == 1 { item = try! JSONSerialization.data(withJSONObject: self.entryItem(login: "refresh-B", mcp: "m2")) }
        }
        try entry(tool).restoreLogin(loginData("refresh-A"))
        XCTAssertEqual(ClaudeCodeKeychainEntry.canonical(tool.item!["claudeAiOauth"]!), loginData("refresh-A"))
    }

    /// Compare-and-swap: a login renewed since Ration read it is not overwritten.
    func testAReplacementExpectingAnotherLoginWritesNothing() {
        let tool = FakeSecurityTool(item: entryItem(login: "refresh-A2"))
        XCTAssertThrowsError(try entry(tool).replaceLogin(with: loginData("refresh-B"), expecting: loginData("refresh-A"))) {
            XCTAssertEqual($0 as? ClaudeCodeKeychainEntry.Failure, .changedBeforeWrite)
        }
        XCTAssertEqual(tool.writes, 0)
    }
}
