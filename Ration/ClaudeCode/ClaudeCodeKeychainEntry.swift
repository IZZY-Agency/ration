import Foundation

/// Claude Code's own sign-in entry (spec §4.1): a JSON object whose
/// `claudeAiOauth` is the Claude login; every other key (`mcpOAuth` …) belongs
/// to Claude Code and is written back exactly as read.
struct ClaudeCodeKeychainEntry: Sendable {
    static let service = "Claude Code-credentials"
    /// `security -i` reads one command line of at most this many characters;
    /// Claude Code passes a longer one on the command line, and so does Ration.
    static let interactiveLineLimit = 4_032
    static let loginKey = "claudeAiOauth"

    enum Failure: Error, Equatable {
        case notFound, unreadable(Int32), notJSON, noLogin, writeFailed(Int32)
        /// Claude Code changed the entry between Ration's reads: nothing was written.
        case changedBeforeWrite
        /// Claude Code changed the entry right after Ration wrote it.
        case conflict
    }

    let tool: any SecurityTool
    let user: String

    func readObject() throws -> [String: Any] {
        let (status, output) = try tool.run(["find-generic-password", "-a", user, "-w", "-s", Self.service], stdin: nil)
        if status == 44 { throw Failure.notFound }
        guard status == 0 else { throw Failure.unreadable(status) }
        var data = output
        if data.last == UInt8(ascii: "\n") { data.removeLast() }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw Failure.notJSON }
        return object
    }

    func login() throws -> Data {
        guard let login = try readObject()[Self.loginKey] else { throw Failure.noLogin }
        return Self.canonical(login)
    }

    /// Read, re-read just before writing (a change in between = Claude Code
    /// wrote), write, read back: the rest must still be what was read, and the
    /// login what was written. The window this cannot see is between the
    /// second read and the write — milliseconds.
    /// `expecting`: the login that must still be there (compare-and-swap) —
    /// a renewal by Claude Code since it was read is never overwritten.
    func replaceLogin(with login: Data, expecting current: Data? = nil) throws {
        let first = try readObject()
        if let current, first[Self.loginKey].map(Self.canonical) != current { throw Failure.changedBeforeWrite }
        let rest = Self.canonical(first.filter { $0.key != Self.loginKey })
        let second = try readObject()
        guard Self.canonical(second) == Self.canonical(first) else { throw Failure.changedBeforeWrite }
        var updated = second
        updated[Self.loginKey] = try JSONSerialization.jsonObject(with: login)
        try write(updated)
        let back = try readObject()
        guard Self.canonical(back.filter { $0.key != Self.loginKey }) == rest,
              back[Self.loginKey].map(Self.canonical) == Self.canonical(try JSONSerialization.jsonObject(with: login))
        else { throw Failure.conflict }
    }

    /// Rollback: put a login back without the conflict check.
    func restoreLogin(_ login: Data) throws {
        var object = try readObject()
        object[Self.loginKey] = try JSONSerialization.jsonObject(with: login)
        try write(object)
    }

    private func write(_ object: [String: Any]) throws {
        let json = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        let hex = json.map { String(format: "%02x", $0) }.joined()
        let line = "add-generic-password -U -a \"\(user)\" -s \"\(Self.service)\" -X \"\(hex)\"\n"
        let status = line.utf8.count <= Self.interactiveLineLimit
            ? try tool.run(["-i"], stdin: Data(line.utf8)).status
            : try tool.run(["add-generic-password", "-U", "-a", user, "-s", Self.service, "-X", hex], stdin: nil).status
        guard status == 0 else { throw Failure.writeFailed(status) }
    }

    /// Sorted-key JSON: the form every comparison uses.
    static func canonical(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])) ?? Data()
    }
}
