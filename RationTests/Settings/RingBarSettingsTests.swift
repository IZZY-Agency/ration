import XCTest
@testable import Ration

/// Settings › General: the Display and window rows serve both surfaces, and
/// the Ring Bar section has its own title in every language.
@MainActor
final class RingBarSettingsTests: XCTestCase {
    func testSharedRowsVisibleWithEitherSurface() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rb-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = AppSettings(fileURL: url)
        try await settings.load()
        XCTAssertTrue(DisplayDetailView.showsSharedGaugeRows(settings))
        try await settings.setShowInUseInMenuBar(false)
        XCTAssertFalse(DisplayDetailView.showsSharedGaugeRows(settings))
        try await settings.setRingBarEnabled(true)
        XCTAssertTrue(DisplayDetailView.showsSharedGaugeRows(settings))
    }

    func testSectionTitleIsLocalized() {
        XCTAssertEqual(SettingsSectionTitle.ringBar(locale: Locale(identifier: "en")), "Ring Bar")
        XCTAssertEqual(SettingsSectionTitle.ringBar(locale: Locale(identifier: "fr")), "Barre d’anneaux")
        XCTAssertEqual(SettingsSectionTitle.ringBar(locale: Locale(identifier: "uk")), "Панель кілець")
        XCTAssertTrue(SettingsSectionTitle.all(locale: Locale(identifier: "en")).contains("Ring Bar"))
        XCTAssertEqual(SettingsSidebar.fixedSelections, [.general, .display, .features, .warmUp, .alerts, .claudeCode])
    }
}
