import Foundation

actor JSONFileStore<Value: Codable & Sendable> {
    private let fileURL: URL
    private let defaultValue: Value

    init(fileURL: URL, defaultValue: Value) {
        self.fileURL = fileURL
        self.defaultValue = defaultValue
    }

    func load() throws -> Value {
        guard FileManager.default.fileExists(
            atPath: fileURL.path(percentEncoded: false)
        ) else {
            return defaultValue
        }

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Value.self, from: data)
    }

    func save(_ value: Value) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        try data.write(to: fileURL, options: .atomic)
    }
}
