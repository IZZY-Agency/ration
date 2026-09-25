import XCTest
@testable import Ration

/// The one resolver every copy function goes through.
final class LocalizedCopyTests: XCTestCase {
    func testAShippedLanguageIsKept() {
        XCTAssertEqual(LocalizedCopy.shippedLocale(for: L10n.fr), L10n.fr)
        XCTAssertEqual(LocalizedCopy.shippedLocale(for: L10n.uk), L10n.uk)
        XCTAssertEqual(LocalizedCopy.shippedLocale(for: L10n.en), L10n.en)
    }

    /// macOS order "de, fr": the bundle runs in French while the locale may
    /// still be German. The resolver follows the bundle. A bundle that holds
    /// only French stands in for that app, so this can fail in any run,
    /// including the English one (English would be the wrong answer here).
    func testAnUnshippedLanguageFallsBackToTheBundleLanguage() throws {
        let bundle: Bundle = try Self.bundle(localizedOnlyIn: "fr")
        addTeardownBlock { try? FileManager.default.removeItem(at: bundle.bundleURL) }
        XCTAssertEqual(bundle.preferredLocalizations.first, "fr", "fixture: the bundle resolves French")

        let resolved: Locale = LocalizedCopy.shippedLocale(for: Locale(identifier: "de_DE"), bundle: bundle)

        XCTAssertEqual(resolved.identifier, "fr")
    }

    /// The whole lookup chain in a translated run: a German locale draws the
    /// run's language, not the English development language a missing
    /// `de.lproj` would otherwise fall back to. In the English run both
    /// answers are English, so there it proves nothing and is skipped; it
    /// runs in `make l10n-test L10N_LANG=fr|uk`.
    func testAnUnshippedLanguageDrawsTheRunsTranslation() throws {
        let code: String = try PinnedTestLanguage.require()
        guard AppLanguage.supported(code) != .english else {
            throw XCTSkip("meaningful only in make l10n-test (fr, uk)")
        }
        let resolved: String = AppLanguage.current.rawValue
        XCTAssertEqual(resolved, code)
        let german: String = LocalizedStringResource.headerFreshnessLive.string(in: Locale(identifier: "de_DE"))

        XCTAssertEqual(german, LocalizedStringResource.headerFreshnessLive.string(in: Locale(identifier: resolved)))
        XCTAssertNotEqual(german, LocalizedStringResource.headerFreshnessLive.string(in: L10n.en))
    }

    /// A throwaway bundle whose only localization is `language`, so its
    /// `preferredLocalizations` is that language whatever the Mac's own order.
    private static func bundle(localizedOnlyIn language: String) throws -> Bundle {
        let root: URL = FileManager.default.temporaryDirectory
            .appending(path: "LocalizedCopyTests-\(UUID().uuidString).bundle", directoryHint: .isDirectory)
        let resources: URL = root.appending(path: "Contents/Resources/\(language).lproj", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data("\"k\" = \"v\";\n".utf8).write(to: resources.appending(path: "Localizable.strings"))
        let info: [String: Any] = [
            "CFBundleIdentifier": "agency.izzy.ration.tests.\(language)-only",
            "CFBundleDevelopmentRegion": language,
            "CFBundlePackageType": "BNDL",
        ]
        let plist: Data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: root.appending(path: "Contents/Info.plist"))
        guard let bundle = Bundle(url: root) else {
            throw XCTSkip("could not open the fixture bundle at \(root.path)")
        }
        return bundle
    }
}
