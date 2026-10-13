import XCTest
@testable import Ration

/// Settings › Display › Popover › Fold accounts not in use, and the accounts
/// the user expanded: defaults, lenient decoding, persistence.
@MainActor
final class AppSettingsPopoverFoldingTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("popover-folding-\(UUID().uuidString).json")
    }

    func testDefaultsFoldAndExpandNothing() async throws {
        let data = AppSettingsData()
        XCTAssertTrue(data.popoverFoldsAccountsNotInUse)
        XCTAssertTrue(data.popoverExpandedAccounts.isEmpty)

        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AppSettings(fileURL: url)
        try await store.load()
        XCTAssertTrue(store.popoverFoldsAccountsNotInUse)
        XCTAssertTrue(store.popoverExpandedAccountIDs.isEmpty)
    }

    /// A file from before this build has neither key: folding on, nothing
    /// expanded, every other setting kept.
    func testMissingKeysDecodeToTheDefaults() throws {
        let data = try JSONDecoder().decode(AppSettingsData.self, from: Data(#"{"sortByWeeklyReset":false}"#.utf8))
        XCTAssertTrue(data.popoverFoldsAccountsNotInUse)
        XCTAssertTrue(data.popoverExpandedAccounts.isEmpty)
        XCTAssertFalse(data.sortByWeeklyReset)
    }

    /// A value this build cannot read falls back alone; an entry that is not
    /// an account id drops alone.
    func testUnreadableValuesFallBackAlone() throws {
        let id = UUID()
        let json = #"{"popoverFoldsAccountsNotInUse":"yes","popoverExpandedAccounts":["\#(id.uuidString)","nope",7],"sortByWeeklyReset":false}"#
        let data = try JSONDecoder().decode(AppSettingsData.self, from: Data(json.utf8))
        XCTAssertTrue(data.popoverFoldsAccountsNotInUse)
        XCTAssertEqual(data.popoverExpandedAccounts, [id.uuidString])
        XCTAssertFalse(data.sortByWeeklyReset)

        let wrongType = try JSONDecoder().decode(AppSettingsData.self, from: Data(#"{"popoverExpandedAccounts":{"a":1}}"#.utf8))
        XCTAssertTrue(wrongType.popoverExpandedAccounts.isEmpty)
    }

    /// Stored canonical — deduplicated, sorted, uppercase — so the file is
    /// stable whatever order the rows were expanded in.
    func testExpandedSetIsCanonical() {
        let a = UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!
        let b = UUID(uuidString: "00000000-0000-4000-8000-00000000000B")!
        let data = AppSettingsData(popoverExpandedAccounts: [b.uuidString, a.uuidString.lowercased(), b.uuidString])
        XCTAssertEqual(data.popoverExpandedAccounts, [a.uuidString, b.uuidString])
        XCTAssertEqual(data.popoverExpandedAccountIDs, [a, b])
    }

    func testExpandingPersistsAndCollapsingRemoves() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AppSettings(fileURL: url)
        try await store.load()
        let work = UUID()
        let client = UUID()

        try await store.setPopoverAccountExpanded(work, true)
        try await store.setPopoverAccountExpanded(client, true)
        try await store.setPopoverAccountExpanded(work, true)
        XCTAssertEqual(store.popoverExpandedAccountIDs, [work, client])

        let reloaded = AppSettings(fileURL: url)
        try await reloaded.load()
        XCTAssertEqual(reloaded.popoverExpandedAccountIDs, [work, client], "remembered across launches")

        try await store.setPopoverAccountExpanded(work, false)
        XCTAssertEqual(store.popoverExpandedAccountIDs, [client])
        try await store.setPopoverAccountExpanded(work, false)
        XCTAssertEqual(store.popoverExpandedAccountIDs, [client])
    }

    func testFoldSwitchPersists() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AppSettings(fileURL: url)
        try await store.load()

        try await store.setPopoverFoldsAccountsNotInUse(false)
        XCTAssertFalse(store.popoverFoldsAccountsNotInUse)

        let reloaded = AppSettings(fileURL: url)
        try await reloaded.load()
        XCTAssertFalse(reloaded.popoverFoldsAccountsNotInUse)
        XCTAssertFalse(reloaded.data.popoverFoldsAccountsNotInUse)
    }

    /// Settings › Display › Popover: the toggle shows the setting and writes
    /// only through its callback (which persists via `AppModel`).
    func testDisplayToggleWritesThroughItsCallback() async throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = AppSettings(fileURL: url)
        try await store.load()
        var written: [Bool] = []

        let binding = DisplayDetailView.foldBinding(settings: store) { written.append($0) }
        XCTAssertTrue(binding.wrappedValue)
        binding.wrappedValue = false

        XCTAssertEqual(written, [false])
        XCTAssertTrue(store.popoverFoldsAccountsNotInUse, "the store changes only through the callback")
    }

    func testDataRoundTrip() throws {
        var data = AppSettingsData()
        data.popoverFoldsAccountsNotInUse = false
        data.popoverExpandedAccounts = [UUID().uuidString]
        let encoded = try JSONEncoder().encode(data)
        XCTAssertEqual(try JSONDecoder().decode(AppSettingsData.self, from: encoded), data)
    }

    func testAppModelSettersPersist() async throws {
        let t0 = Date(timeIntervalSince1970: 100_000)
        let fixture = try makeAlertsFixture(now: { t0 })
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let id = UUID()

        try await fixture.model.setPopoverAccountExpanded(id, true)
        try await fixture.model.setPopoverFoldsAccountsNotInUse(false)

        XCTAssertEqual(fixture.model.settings.popoverExpandedAccountIDs, [id])
        XCTAssertFalse(fixture.model.settings.popoverFoldsAccountsNotInUse)
    }
}
