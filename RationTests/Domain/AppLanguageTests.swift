import XCTest
@testable import Ration

final class AppLanguageTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "AppLanguageTests-\(UUID())"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    private func stored() -> AppLanguage { AppLanguage.stored(in: defaults, domain: suiteName) }
    private func store(_ language: AppLanguage) { AppLanguage.store(language, in: defaults, domain: suiteName) }

    private var storedValue: Any? {
        defaults.persistentDomain(forName: suiteName)?["AppleLanguages"]
    }

    func testStoreFrenchWritesSingleLanguageOverride() {
        store(.french)
        XCTAssertEqual(storedValue as? [String], ["fr"])
    }

    func testStoreSystemRemovesOverride() {
        store(.ukrainian)
        store(.system)
        XCTAssertNil(storedValue)
        XCTAssertEqual(stored(), .system)
    }

    func testStoredRoundTripsEveryLanguage() {
        for language in AppLanguage.allCases {
            store(language)
            XCTAssertEqual(stored(), language)
        }
    }

    func testNothingStoredIsSystem() {
        XCTAssertEqual(stored(), .system)
    }

    func testUnknownStoredValueIsSystem() {
        defaults.set(["de"], forKey: "AppleLanguages")
        XCTAssertEqual(stored(), .system)
        defaults.set("fr", forKey: "AppleLanguages") // not an array
        XCTAssertEqual(stored(), .system)
        defaults.set(["fr", "uk"], forKey: "AppleLanguages") // not one we wrote
        XCTAssertEqual(stored(), .system)
    }

    /// `-testLanguage` puts `AppleLanguages` in the argument domain, which
    /// shadows every domain for `object(forKey:)`; the stored choice must
    /// still read back.
    func testStoredIgnoresShadowingDomains() throws {
        let pinned = try PinnedTestLanguage.require()
        let other: AppLanguage = pinned == AppLanguage.ukrainian.rawValue ? .french : .ukrainian
        store(other)
        XCTAssertEqual((defaults.array(forKey: "AppleLanguages") as? [String])?.first, pinned, "argument domain should shadow the suite")
        XCTAssertEqual(stored(), other)
    }

    func testStoredMapsRegionalCodesByLanguage() {
        let cases: [(String, AppLanguage)] = [
            ("fr-FR", .french), ("fr-CA", .french), ("fr_CA", .french),
            ("uk-UA", .ukrainian), ("en-GB", .english), ("en", .english),
            ("de-DE", .system), ("system", .system),
        ]
        for (code, expected) in cases {
            defaults.set([code], forKey: "AppleLanguages")
            XCTAssertEqual(stored(), expected, code)
        }
    }

    /// A suite's value never leaks into the app's own domain or back.
    func testStoredReadsOnlyTheNamedDomain() {
        store(.french)
        XCTAssertEqual(AppLanguage.stored(in: defaults, domain: "AppLanguageTests-unrelated-\(UUID())"), .system)
    }

    func testResolvedMapsBundlePreferredLocalization() throws {
        XCTAssertEqual(AppLanguage.resolved(bundle: try bundle(localizations: ["uk"])), .ukrainian)
        XCTAssertEqual(AppLanguage.resolved(bundle: try bundle(localizations: ["fr"])), .french)
        XCTAssertEqual(AppLanguage.resolved(bundle: try bundle(localizations: ["en"])), .english)
    }

    func testResolvedFallsBackToEnglishForUnsupported() throws {
        XCTAssertEqual(AppLanguage.resolved(first: "de"), .english)
        XCTAssertEqual(AppLanguage.resolved(first: nil), .english)
        XCTAssertEqual(AppLanguage.resolved(first: "uk"), .ukrainian)
        XCTAssertEqual(AppLanguage.resolved(first: "fr-CA"), .french)
    }

    func testResolvedIsNeverSystem() {
        XCTAssertNotEqual(AppLanguage.current, .system)
    }

    /// `make unit-test` / `make l10n-test L10N_LANG=` pin the run's language through
    /// the argument domain; the bundle must resolve that same language, or the
    /// fr/uk runs would silently test English.
    func testCurrentFollowsThePinnedTestLanguage() throws {
        let pinned = try PinnedTestLanguage.require() // outside the assertion, which would swallow the skip
        XCTAssertEqual(AppLanguage.current.rawValue, pinned)
    }

    func testIDIsRawValue() {
        XCTAssertEqual(AppLanguage.french.id, "fr")
        XCTAssertEqual(AppLanguage.system.id, "system")
    }

    func testNativeNamesAreEndonyms() {
        XCTAssertEqual(AppLanguage.english.nativeName, "English")
        XCTAssertEqual(AppLanguage.french.nativeName, "Français")
        XCTAssertEqual(AppLanguage.ukrainian.nativeName, "Українська")
        XCTAssertFalse(AppLanguage.system.nativeName.isEmpty)
    }

    /// A throwaway bundle on disk whose only localization is `localizations`,
    /// so `preferredLocalizations` can resolve to nothing else.
    private func bundle(localizations: [String]) throws -> Bundle {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLanguageTests-\(UUID()).bundle")
        let resources = root.appendingPathComponent("Contents/Resources")
        for code in localizations {
            let lproj = resources.appendingPathComponent("\(code).lproj")
            try FileManager.default.createDirectory(at: lproj, withIntermediateDirectories: true)
            try Data("\"k\" = \"v\";".utf8).write(to: lproj.appendingPathComponent("Localizable.strings"))
        }
        let info: [String: Any] = [
            "CFBundleIdentifier": "test.\(UUID())",
            "CFBundleDevelopmentRegion": localizations[0],
            "CFBundleLocalizations": localizations,
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: root.appendingPathComponent("Contents/Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try XCTUnwrap(Bundle(url: root))
    }
}
