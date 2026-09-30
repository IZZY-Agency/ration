import XCTest

/// One word per idea, per language — a new string must use the app's own
/// term, not a synonym that reads as a different thing.
final class CatalogTerminologyTests: XCTestCase {
    private static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Localization
            .deletingLastPathComponent() // RationTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Ration/Resources/Localizable.xcstrings")
    }

    /// Ukrainian says "обліковий запис" for an account (72 strings on
    /// 2026-09-29); "акаунт" slipped into the Claude Code strings once.
    func testUkrainianSaysOblikovyiZapysNotAkaunt() throws {
        let catalog = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: Self.catalogURL)) as? [String: Any])
        let strings = try XCTUnwrap(catalog["strings"] as? [String: [String: Any]])
        var offenders: [String] = []
        for (key, entry) in strings {
            let localizations = entry["localizations"] as? [String: [String: Any]]
            let unit = localizations?["uk"]?["stringUnit"] as? [String: Any]
            if let value = unit?["value"] as? String, value.lowercased().contains("акаунт") { offenders.append(key) }
        }
        XCTAssertEqual(offenders.sorted(), [])
    }
}
