import XCTest
@testable import Ration

final class AboutAppInfoTests: XCTestCase {
    func testFormatsCompleteBundleMetadata() {
        let info = AboutAppInfo(infoDictionary: [
            "CFBundleDisplayName": "Ration",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "NSHumanReadableCopyright": "Copyright © 2026 IZZY.Agency"
        ])

        XCTAssertEqual(info.displayName, "Ration")
        XCTAssertEqual(info.versionText, "Version 0.1.0 (1)")
        XCTAssertEqual(
            info.copyrightText,
            "Copyright © 2026 IZZY.Agency"
        )
    }

    /// The bundle's line is one sentence in English; its year and holder are
    /// re-set in the catalog's sentence for the UI language.
    func testCopyrightIsLocalizedAroundTheBundlesYearAndHolder() {
        let info: [String: Any] = ["NSHumanReadableCopyright": "Copyright © 2026 IZZY.Agency"]

        XCTAssertEqual(AboutAppInfo(infoDictionary: info, locale: L10n.en).copyrightText, "Copyright © 2026 IZZY.Agency")
        XCTAssertEqual(AboutAppInfo(infoDictionary: info, locale: L10n.fr).copyrightText, "Copyright © 2026 IZZY.Agency")
        XCTAssertEqual(AboutAppInfo(infoDictionary: info, locale: L10n.uk).copyrightText, "© 2026 IZZY.Agency. Усі права захищено.")
    }

    /// Guards project.yml: the shipped line must keep the shape the
    /// localization recognises, or every language falls back to English.
    func testShippedCopyrightLineIsLocalized() throws {
        let line = try XCTUnwrap(Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String)
        let info: [String: Any] = ["NSHumanReadableCopyright": line]

        XCTAssertEqual(AboutAppInfo(infoDictionary: info, locale: L10n.en).copyrightText, line)
        let ukrainian = AboutAppInfo(infoDictionary: info, locale: L10n.uk).copyrightText
        XCTAssertTrue(ukrainian.hasSuffix("Усі права захищено."), ukrainian)
    }

    func testCopyrightYearRangeIsKept() {
        let info: [String: Any] = ["NSHumanReadableCopyright": "Copyright © 2026–2027 IZZY.Agency"]

        XCTAssertEqual(AboutAppInfo(infoDictionary: info, locale: L10n.uk).copyrightText, "© 2026–2027 IZZY.Agency. Усі права захищено.")
    }

    /// A line in any other shape is shown as the bundle has it, never
    /// guessed at.
    func testUnrecognisedCopyrightIsShownVerbatim() {
        let info: [String: Any] = ["NSHumanReadableCopyright": "© IZZY.Agency, all rights reserved"]

        XCTAssertEqual(AboutAppInfo(infoDictionary: info, locale: L10n.uk).copyrightText, "© IZZY.Agency, all rights reserved")
    }

    func testMissingMetadataIsReportedWithoutInventingValues() {
        let info = AboutAppInfo(infoDictionary: [:])

        XCTAssertEqual(info.displayName, "Application")
        XCTAssertEqual(info.versionText, "Version unavailable")
        XCTAssertEqual(info.copyrightText, "Copyright unavailable")
    }
}
