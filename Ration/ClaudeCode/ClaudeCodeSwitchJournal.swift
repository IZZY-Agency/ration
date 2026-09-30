import Foundation

/// Written before a switch touches anything, deleted when it completes
/// (spec §4.1): the settings file's original bytes, so an interrupted or
/// failed switch can put them back — also at the next launch. No token.
struct ClaudeCodeSwitchJournal: Codable, Equatable, Sendable {
    let startedAt: Date
    let from: String
    let to: String
    let config: Data
}

protocol ClaudeCodeJournalStore: Sendable {
    /// nil when there is none, or it cannot be read.
    func read() -> ClaudeCodeSwitchJournal?
    func write(_ journal: ClaudeCodeSwitchJournal) throws
    func clear() throws
}

struct ClaudeCodeJournalFile: ClaudeCodeJournalStore {
    let url: URL

    func read() -> ClaudeCodeSwitchJournal? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ClaudeCodeSwitchJournal.self, from: data)
    }

    func write(_ journal: ClaudeCodeSwitchJournal) throws {
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
