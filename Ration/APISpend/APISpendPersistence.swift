import Foundation

/// The ONLY writer of `api-spend.json` and `api-spend-snapshots.json`.
/// Every write encodes the model's LIVE value at execution time, so the last
/// writer is always right; a nil live value means the caller's decision is
/// stale and nothing is written.
@MainActor
final class APISpendPersistence {
    typealias WriteData = @Sendable (Data, URL) throws -> Void

    private let stateURL: URL
    private let snapshotsURL: URL
    private let writeData: WriteData
    private let queue = SerializedMutationQueue()

    init(stateURL: URL, snapshotsURL: URL, writeData: WriteData? = nil) {
        self.stateURL = stateURL
        self.snapshotsURL = snapshotsURL
        self.writeData = writeData ?? { data, url in
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    func loadState() async throws -> APISpendState {
        guard FileManager.default.fileExists(atPath: stateURL.path(percentEncoded: false)) else { return APISpendState() }
        return try Self.decoder().decode(APISpendState.self, from: Data(contentsOf: stateURL))
    }

    /// A display cache: an unreadable file is an empty cache, never an error.
    func loadSnapshots() async -> [UUID: APISpendSnapshot] {
        guard let data = try? Data(contentsOf: snapshotsURL) else { return [:] }
        return (try? Self.decoder().decode([UUID: APISpendSnapshot].self, from: data)) ?? [:]
    }

    func writeState(_ live: @escaping @MainActor () -> APISpendState?) async -> PersistOutcome {
        await write(to: stateURL) { try live().map { try Self.encoder().encode($0) } }
    }

    func writeSnapshots(_ live: @escaping @MainActor () -> [UUID: APISpendSnapshot]?) async -> PersistOutcome {
        await write(to: snapshotsURL) { try live().map { try Self.encoder().encode($0) } }
    }

    /// Carries the outcome out of the serialized closure (Swift 6 forbids
    /// mutating a captured local from it).
    @MainActor private final class OutcomeBox { var value = PersistOutcome.failed }

    private func write(to url: URL, encode: @escaping @MainActor () throws -> Data?) async -> PersistOutcome {
        let box = OutcomeBox()
        let writeData = self.writeData
        do {
            try await queue.run {
                guard let data = try encode() else { box.value = .stale; return }
                try writeData(data, url)
                box.value = .written
            }
        } catch {
            box.value = .failed
        }
        return box.value
    }
}
