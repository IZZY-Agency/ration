import XCTest
@testable import Ration

/// The ring bar's four settings: off by default, and lenient — a value this
/// build does not know (a newer build's, a hand edit) falls back alone instead
/// of costing the user every other setting.
@MainActor
final class AppSettingsRingBarTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ringbar-\(UUID().uuidString).json")
    }

    func testDefaultsAreOffRailLeftNoHide() {
        let data = AppSettingsData()
        XCTAssertFalse(data.ringBarEnabled)
        XCTAssertEqual(data.ringBarStyle, .rail)
        XCTAssertEqual(data.ringBarEdge, .left)
        XCTAssertFalse(data.ringBarHidesAtEdge)
    }

    func testMissingKeysDecodeToDefaults() throws {
        let data = try JSONDecoder().decode(AppSettingsData.self, from: Data("{}".utf8))
        XCTAssertFalse(data.ringBarEnabled)
        XCTAssertEqual(data.ringBarStyle, .rail)
        XCTAssertEqual(data.ringBarEdge, .left)
        XCTAssertFalse(data.ringBarHidesAtEdge)
    }

    func testUnknownRingBarValuesFallBackAlone() throws {
        let json = #"{"ringBarEnabled": true, "ringBarStyle": "dock", "ringBarEdge": "diagonal", "ringBarHidesAtEdge": "yes", "sortByWeeklyReset": false, "quietHours": [3]}"#
        let data = try JSONDecoder().decode(AppSettingsData.self, from: Data(json.utf8))
        XCTAssertTrue(data.ringBarEnabled)
        XCTAssertEqual(data.ringBarStyle, .rail)
        XCTAssertEqual(data.ringBarEdge, .left)
        XCTAssertFalse(data.ringBarHidesAtEdge)
        XCTAssertFalse(data.sortByWeeklyReset)
        XCTAssertEqual(data.quietHours, [3])
    }

    func testSettersPersistAndPublish() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AppSettings(fileURL: url)
        try await store.load()
        try await store.setRingBarEnabled(true)
        try await store.setRingBarStyle(.capsules)
        try await store.setRingBarEdge(.bottom)
        try await store.setRingBarHidesAtEdge(true)

        XCTAssertTrue(store.ringBarEnabled)
        XCTAssertEqual(store.ringBarStyle, .capsules)
        XCTAssertEqual(store.ringBarEdge, .bottom)
        XCTAssertTrue(store.ringBarHidesAtEdge)

        let reloaded = AppSettings(fileURL: url)
        try await reloaded.load()
        XCTAssertTrue(reloaded.data.ringBarEnabled)
        XCTAssertEqual(reloaded.data.ringBarStyle, .capsules)
        XCTAssertEqual(reloaded.data.ringBarEdge, .bottom)
        XCTAssertTrue(reloaded.data.ringBarHidesAtEdge)
    }

    func testWantsGaugesWhenEitherSurfaceIsOn() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AppSettings(fileURL: url)
        try await store.load()
        XCTAssertTrue(store.wantsGauges)
        try await store.setShowInUseInMenuBar(false)
        XCTAssertFalse(store.wantsGauges)
        try await store.setRingBarEnabled(true)
        XCTAssertTrue(store.wantsGauges)
    }

    func testTitlesAreLocalized() {
        let en = Locale(identifier: "en"), fr = Locale(identifier: "fr"), uk = Locale(identifier: "uk")
        XCTAssertEqual(RingBarStyle.rail.title(locale: en), "Rail")
        XCTAssertEqual(RingBarStyle.capsules.title(locale: en), "Capsules")
        XCTAssertEqual(RingBarEdge.left.title(locale: en), "Left")
        XCTAssertEqual(RingBarEdge.bottom.title(locale: fr), "Bas")
        XCTAssertEqual(RingBarEdge.top.title(locale: uk), "Угорі")
        XCTAssertTrue(RingBarEdge.left.isVertical)
        XCTAssertFalse(RingBarEdge.top.isVertical)
    }
}
