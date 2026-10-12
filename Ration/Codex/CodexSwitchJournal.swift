import Foundation

/// Written before a switch touches `~/.codex/auth.json`, deleted when it
/// resolves (spec §4.1). No bytes, no token: the remembered copy it names —
/// the left login's copy saved at `fromSavedAt` — is the rollback source, and
/// a copy re-saved since does not qualify.
struct CodexSwitchJournal: Codable, Equatable, Sendable {
    let startedAt: Date
    /// Login ids (`CodexLogin.id`).
    let from: String
    let to: String
    /// nil when the login being left was not remembered (the user let it go):
    /// there is nothing to roll back to.
    let fromSavedAt: Date?
}

protocol CodexJournalStore: Sendable {
    /// nil when there is none. Throws when there is one that cannot be read
    /// or decoded: never taken for "no journal".
    func read() throws -> CodexSwitchJournal?
    func write(_ journal: CodexSwitchJournal) throws
    func clear() throws
}

/// `codex-switch-journal.json` in Ration's container.
struct CodexJournalFile: CodexJournalStore {
    let url: URL

    func read() throws -> CodexSwitchJournal? {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile, CocoaError.fileNoSuchFile {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(CodexSwitchJournal.self, from: data)
    }

    func write(_ journal: CodexSwitchJournal) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(journal).write(to: url, options: .atomic)
    }

    func clear() throws {
        do {
            try FileManager.default.removeItem(at: url)
        } catch CocoaError.fileNoSuchFile {}
    }
}
