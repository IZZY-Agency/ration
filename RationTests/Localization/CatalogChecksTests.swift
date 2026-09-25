import XCTest

/// Each `CatalogChecks` rule, against catalogs small enough to read: a correct
/// entry passes every rule, and each defect is reported by the rule that owns
/// it and names the key.
final class CatalogChecksTests: XCTestCase {
    // MARK: - Fixture builders

    private func unit(_ value: String?, state: String = "translated") -> [String: Any] {
        var unit: [String: Any] = ["state": state]
        if let value { unit["value"] = value }
        return ["stringUnit": unit]
    }

    private func plural(_ categories: [String: String]) -> [String: Any] {
        ["variations": ["plural": categories.mapValues { unit($0) }]]
    }

    private func catalog(_ entries: [String: [String: Any]]) -> CatalogChecks.Node {
        ["sourceLanguage": "en", "version": "1.0", "strings": entries]
    }

    private func entry(_ localizations: [String: Any], comment: String = "c", state: String = "manual") -> [String: Any] {
        ["comment": comment, "extractionState": state, "localizations": localizations]
    }

    private var plain: [String: Any] {
        entry(["en": unit("Hello, %@"), "fr": unit("Bonjour, %@"), "uk": unit("Привіт, %@")])
    }

    private var hours: [String: Any] {
        entry([
            "en": plural(["one": "%lld hour", "other": "%lld hours"]),
            "fr": plural(["one": "%lld heure", "many": "%lld heures", "other": "%lld heures"]),
            "uk": plural(["one": "%lld година", "few": "%lld години", "many": "%lld годин", "other": "%lld години"]),
        ])
    }

    private func assertAllPass(_ root: CatalogChecks.Node, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(CatalogChecks.missingComments(in: root), [], file: file, line: line)
        XCTAssertEqual(CatalogChecks.untranslated(in: root), [], file: file, line: line)
        XCTAssertEqual(CatalogChecks.pluralGaps(in: root), [], file: file, line: line)
        XCTAssertEqual(CatalogChecks.placeholderMismatches(in: root), [], file: file, line: line)
    }

    private func assertFlags(_ offending: [String], _ key: String, _ detail: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(
            offending.contains { $0.hasPrefix(key) && $0.contains(detail) },
            "expected \(key) … \(detail) in \(offending)", file: file, line: line
        )
    }

    // MARK: - Passing entries

    func testCorrectPlainEntryPassesEveryRule() {
        assertAllPass(catalog(["k": plain]))
    }

    func testCorrectPluralEntryPassesEveryRule() {
        assertAllPass(catalog(["k": hours]))
    }

    func testStaleKeysAreIgnored() {
        assertAllPass(catalog(["gone": entry(["en": unit("Old")], comment: "", state: "stale")]))
    }

    // MARK: - untranslated

    func testMissingFrenchIsFlagged() {
        var bad = plain
        bad["localizations"] = ["en": unit("Hello, %@"), "uk": unit("Привіт, %@")]
        assertFlags(CatalogChecks.untranslated(in: catalog(["k": bad])), "k", "fr missing")
    }

    func testMissingUkrainianIsFlagged() {
        var bad = plain
        bad["localizations"] = ["en": unit("Hello, %@"), "fr": unit("Bonjour, %@")]
        assertFlags(CatalogChecks.untranslated(in: catalog(["k": bad])), "k", "uk missing")
    }

    func testStateOtherThanTranslatedIsFlagged() {
        let bad = entry(["en": unit("Hi"), "fr": unit("Salut"), "uk": unit("Привіт", state: "needs_review")])
        assertFlags(CatalogChecks.untranslated(in: catalog(["k": bad])), "k", "uk state=needs_review")
    }

    func testEmptyValueIsFlagged() {
        let bad = entry(["en": unit("Hi"), "fr": unit(""), "uk": unit("Привіт")])
        assertFlags(CatalogChecks.untranslated(in: catalog(["k": bad])), "k", "fr empty value")
    }

    func testUnitWithoutValueIsFlagged() {
        let bad = entry(["en": unit("Hi"), "fr": unit(nil), "uk": unit("Привіт")])
        assertFlags(CatalogChecks.untranslated(in: catalog(["k": bad])), "k", "fr empty value")
    }

    func testEmptyLocalizationIsFlagged() {
        let bad = entry(["en": unit("Hi"), "fr": [String: Any](), "uk": unit("Привіт")])
        assertFlags(CatalogChecks.untranslated(in: catalog(["k": bad])), "k", "fr has no string unit")
    }

    func testEmptyEnglishValueIsFlagged() {
        let bad = entry(["en": unit(""), "fr": unit("Salut"), "uk": unit("Привіт")])
        assertFlags(CatalogChecks.untranslated(in: catalog(["k": bad])), "k", "en empty value")
    }

    func testMissingCommentIsFlagged() {
        var bad = plain
        bad["comment"] = ""
        XCTAssertEqual(CatalogChecks.missingComments(in: catalog(["k": bad])), ["k"])
    }

    // MARK: - pluralGaps

    func testUkrainianMissingFewAndManyIsFlagged() {
        var bad = hours
        var localizations = bad["localizations"] as! [String: Any]
        localizations["uk"] = plural(["one": "%lld година", "other": "%lld години"])
        bad["localizations"] = localizations
        assertFlags(CatalogChecks.pluralGaps(in: catalog(["k": bad])), "k", "uk missing [\"few\", \"many\"]")
    }

    func testFrenchMissingOneIsFlagged() {
        var bad = hours
        var localizations = bad["localizations"] as! [String: Any]
        localizations["fr"] = plural(["many": "%lld heures", "other": "%lld heures"])
        bad["localizations"] = localizations
        assertFlags(CatalogChecks.pluralGaps(in: catalog(["k": bad])), "k", "fr missing [\"one\"]")
    }

    func testFrenchMissingOtherIsFlagged() {
        var bad = hours
        var localizations = bad["localizations"] as! [String: Any]
        localizations["fr"] = plural(["one": "%lld heure", "many": "%lld heures"])
        bad["localizations"] = localizations
        assertFlags(CatalogChecks.pluralGaps(in: catalog(["k": bad])), "k", "fr missing [\"other\"]")
    }

    /// CLDR gives French a `many` category (1 000 000 de …) in current
    /// Apple catalogs; an entry without it silently falls back to `other`.
    func testFrenchMissingManyIsFlagged() {
        var bad = hours
        var localizations = bad["localizations"] as! [String: Any]
        localizations["fr"] = plural(["one": "%lld heure", "other": "%lld heures"])
        bad["localizations"] = localizations
        assertFlags(CatalogChecks.pluralGaps(in: catalog(["k": bad])), "k", "fr missing [\"many\"]")
    }

    func testTranslationWithoutPluralIsFlagged() {
        var bad = hours
        var localizations = bad["localizations"] as! [String: Any]
        localizations["fr"] = unit("%lld heures")
        bad["localizations"] = localizations
        assertFlags(CatalogChecks.pluralGaps(in: catalog(["k": bad])), "k", "fr has no plural variation")
    }

    // MARK: - placeholderMismatches

    func testTopLevelPlaceholderMismatchIsFlagged() {
        let bad = entry(["en": unit("Hello, %@"), "fr": unit("Bonjour, %lld"), "uk": unit("Привіт, %@")])
        assertFlags(CatalogChecks.placeholderMismatches(in: catalog(["k": bad])), "k", "[fr]")
    }

    func testDroppedPlaceholderIsFlagged() {
        let bad = entry(["en": unit("Hello, %@"), "fr": unit("Bonjour"), "uk": unit("Привіт, %@")])
        assertFlags(CatalogChecks.placeholderMismatches(in: catalog(["k": bad])), "k", "[fr]")
    }

    func testPluralCategoryIsComparedWithTheSameEnglishCategory() {
        let bad = entry([
            "en": plural(["one": "one hour", "other": "%lld hours"]),
            "fr": plural(["one": "une heure", "many": "%lld heures", "other": "%lld heures"]),
            "uk": plural(["one": "%lld година", "few": "%lld години", "many": "%lld годин", "other": "%lld години"]),
        ])
        // uk `one` carries %lld where English `one` has none.
        assertFlags(CatalogChecks.placeholderMismatches(in: catalog(["k": bad])), "k", "[uk.plural.one]")
        XCTAssertFalse(CatalogChecks.placeholderMismatches(in: catalog(["k": bad])).contains { $0.contains("[fr") })
    }

    func testCategoryEnglishLacksFallsBackToEnglishOther() {
        let bad = entry([
            "en": plural(["one": "%lld hour", "other": "%lld hours"]),
            "fr": plural(["one": "%lld heure", "many": "%lld heures", "other": "%lld heures"]),
            "uk": plural(["one": "%lld година", "few": "%@ години", "many": "%lld годин", "other": "%lld години"]),
        ])
        XCTAssertEqual(CatalogChecks.placeholderMismatches(in: catalog(["k": bad])).count, 1)
        assertFlags(CatalogChecks.placeholderMismatches(in: catalog(["k": bad])), "k", "[uk.plural.few]")
    }

    func testSubstitutionVariantIsComparedWithItsEnglishVariant() {
        func localization(_ top: String, _ one: String, _ other: String) -> [String: Any] {
            [
                "stringUnit": ["state": "translated", "value": top],
                "substitutions": ["count": [
                    "argNum": 1, "formatSpecifier": "lld",
                    "variations": ["plural": ["one": unit(one), "other": unit(other)]],
                ]],
            ]
        }
        let bad = entry([
            "en": localization("%#@count@ left", "%arg hour", "%arg hours"),
            // fr top level drops the substitution for a raw %lld.
            "fr": localization("%lld restantes", "%arg heure", "%arg heures"),
            "uk": localization("%#@count@ залишилось", "%arg година", "%arg годин"),
        ])
        let offending = CatalogChecks.placeholderMismatches(in: catalog(["k": bad]))
        XCTAssertEqual(offending.count, 1, "\(offending)")
        assertFlags(offending, "k", "[fr]")
    }

    func testKeyWithoutEnglishUnitUsesTheKey() {
        let good = entry(["fr": unit("Bonjour, %@"), "uk": unit("Привіт, %@")])
        XCTAssertEqual(CatalogChecks.placeholderMismatches(in: catalog(["Hello, %@": good])), [])
        let bad = entry(["fr": unit("Bonjour"), "uk": unit("Привіт, %@")])
        assertFlags(CatalogChecks.placeholderMismatches(in: catalog(["Hello, %@": bad])), "Hello, %@", "[fr]")
    }

    // MARK: - placeholders

    func testPlaceholderParserCountsEachSpecifier() {
        XCTAssertEqual(CatalogChecks.placeholders("%@ and %lld of %1$@, 100%%"), ["%@": 1, "%lld": 1, "%1$@": 1])
        XCTAssertEqual(CatalogChecks.placeholders("%@ %@"), ["%@": 2])
        XCTAssertEqual(CatalogChecks.placeholders("%#@count@ and %arg"), ["%#@count@": 1, "%arg": 1])
        XCTAssertEqual(CatalogChecks.placeholders("no args"), [:])
    }
}
