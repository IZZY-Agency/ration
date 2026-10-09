import XCTest
@testable import Ration

/// Per-gauge visibility and the ring bar's scale: defaults change nothing,
/// and a value this build cannot read falls back alone.
@MainActor
final class AppSettingsDisplayTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("display-\(UUID().uuidString).json")
    }

    func testDefaultsShowEverythingAtScaleOne() {
        let data = AppSettingsData()
        XCTAssertTrue(data.gaugeVisibility.isEmpty)
        XCTAssertEqual(data.ringBarScale, 1)
        XCTAssertTrue(data.shows(.menuBar, id: UUID()))
        XCTAssertTrue(data.shows(.ringBar, id: UUID()))
    }

    func testUnknownValuesFallBackAlone() throws {
        let id = UUID()
        let json = #"{"ringBarScale": "huge", "gaugeVisibility": {"\#(id.uuidString)": {"menuBar": false}, "bad": 7}, "sortByWeeklyReset": false}"#
        let data = try JSONDecoder().decode(AppSettingsData.self, from: Data(json.utf8))
        XCTAssertEqual(data.ringBarScale, 1)
        XCTAssertFalse(data.shows(.menuBar, id: id))
        XCTAssertTrue(data.shows(.ringBar, id: id))
        XCTAssertNil(data.gaugeVisibility["bad"])
        XCTAssertFalse(data.sortByWeeklyReset)
    }

    func testScaleIsClampedOnDecode() throws {
        let big = try JSONDecoder().decode(AppSettingsData.self, from: Data(#"{"ringBarScale": 5}"#.utf8))
        XCTAssertEqual(big.ringBarScale, 1.8)
        let small = try JSONDecoder().decode(AppSettingsData.self, from: Data(#"{"ringBarScale": 0.1}"#.utf8))
        XCTAssertEqual(small.ringBarScale, 0.8)
    }

    func testSettersPersistClampAndTidy() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AppSettings(fileURL: url)
        try await store.load()
        let id = UUID()

        try await store.setShows(.ringBar, id: id, false)
        XCTAssertFalse(store.shows(.ringBar, id: id))
        XCTAssertTrue(store.shows(.menuBar, id: id))
        try await store.setRingBarScale(9)
        XCTAssertEqual(store.ringBarScale, 1.8)

        let reloaded = AppSettings(fileURL: url)
        try await reloaded.load()
        XCTAssertFalse(reloaded.shows(.ringBar, id: id))
        XCTAssertEqual(reloaded.ringBarScale, 1.8)

        try await store.setShows(.ringBar, id: id, true)
        XCTAssertNil(store.gaugeVisibility[id.uuidString], "an all-shown entry is removed")
        try await store.setRingBarScale(0.85)
        XCTAssertEqual(store.ringBarScale, 0.85, accuracy: 0.0001)
    }
}
