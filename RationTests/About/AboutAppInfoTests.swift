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

    func testMissingMetadataIsReportedWithoutInventingValues() {
        let info = AboutAppInfo(infoDictionary: [:])

        XCTAssertEqual(info.displayName, "Application")
        XCTAssertEqual(info.versionText, "Version unavailable")
        XCTAssertEqual(info.copyrightText, "Copyright unavailable")
    }
}
