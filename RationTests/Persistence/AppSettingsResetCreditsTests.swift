import XCTest
@testable import Ration

@MainActor
final class AppSettingsResetCreditsTests: XCTestCase {
    func testDefaultsToOneDayAndClamps() throws {
        var data = AppSettingsData()
        XCTAssertEqual(data.resetExpiryLeadDays(provider: .claude), 1)
        data.resetExpiryLeadDays["claude"] = 99
        XCTAssertEqual(data.resetExpiryLeadDays(provider: .claude), 7)
        data.resetExpiryLeadDays["claude"] = 0
        XCTAssertEqual(data.resetExpiryLeadDays(provider: .claude), 1)
    }

    func testLegacyAndMalformedFilesDecode() throws {
        let legacy = try JSONDecoder().decode(AppSettingsData.self, from: Data(#"{"usageAlertsEnabled":true}"#.utf8))
        XCTAssertEqual(legacy.resetExpiryLeadDays, [:])
        XCTAssertTrue(legacy.usageAlertsEnabled)
        let mixed = try JSONDecoder().decode(AppSettingsData.self, from: Data(#"{"quietHours":[3],"resetExpiryLeadDays":{"claude":3,"chatgpt":"x"}}"#.utf8))
        XCTAssertEqual(mixed.resetExpiryLeadDays, ["claude": 3])
        XCTAssertEqual(mixed.quietHours, [3], "a bad entry never resets other settings")
    }

    func testSetterPersists() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "app-settings.json")
        let settings = AppSettings(fileURL: url)
        try await settings.load()
        try await settings.setResetExpiryLeadDays(3, provider: .chatGPT)
        let reloaded = AppSettings(fileURL: url)
        try await reloaded.load()
        XCTAssertEqual(reloaded.data.resetExpiryLeadDays(provider: .chatGPT), 3)
        XCTAssertEqual(reloaded.data.resetExpiryLeadDays(provider: .claude), 1)
    }

    func testResetChannelsDefaultToBoth() {
        XCTAssertEqual(AppSettingsData().channels(forKey: AppSettingsData.resetCreditsKey(provider: .claude)), .default)
    }
}
