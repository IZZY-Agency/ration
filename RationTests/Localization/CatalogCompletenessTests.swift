import XCTest

/// Guards `Localizable.xcstrings` itself, read straight from the source tree:
/// every live key is translated into every shipped language, carries the
/// plural categories its language needs, and keeps the English placeholders.
/// The rules live in `CatalogChecks`; `CatalogChecksTests` proves each fires.
final class CatalogCompletenessTests: XCTestCase {
    private static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Localization
            .deletingLastPathComponent() // RationTests
            .deletingLastPathComponent() // repo root
            .appendingPathComponent("Ration/Resources/Localizable.xcstrings")
    }

    private func catalog() throws -> CatalogChecks.Node {
        try CatalogChecks.decode(Data(contentsOf: Self.catalogURL))
    }

    func testCatalogIsEnglishSourcedAndNotEmpty() throws {
        let root = try catalog()
        XCTAssertEqual(root["sourceLanguage"] as? String, "en")
        XCTAssertFalse(CatalogChecks.liveEntries(root).isEmpty)
    }

    func testEveryKeyHasATranslatorComment() throws {
        XCTAssertEqual(CatalogChecks.missingComments(in: try catalog()), [], "keys without a translator comment")
    }

    func testEveryKeyIsTranslated() throws {
        XCTAssertEqual(CatalogChecks.untranslated(in: try catalog()), [], "untranslated keys")
    }

    func testPluralVariationsCoverEveryCategory() throws {
        XCTAssertEqual(CatalogChecks.pluralGaps(in: try catalog()), [], "incomplete plural variations")
    }

    func testPlaceholdersMatchEnglish() throws {
        XCTAssertEqual(CatalogChecks.placeholderMismatches(in: try catalog()), [], "placeholder mismatches")
    }
}
