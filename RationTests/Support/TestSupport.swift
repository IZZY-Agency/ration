import Foundation

/// Shared test helper: creates a fresh temporary directory for filesystem-backed
/// persistence tests. Callers are responsible for removing it (typically via
/// `defer { try? FileManager.default.removeItem(at: directory) }`).
func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
    )
    return directory
}
