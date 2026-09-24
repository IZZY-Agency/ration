import SwiftUI
import XCTest
@testable import Ration

/// `popoverLayout` through the whole settings path, the General pane's
/// picker, and `AppModel.focusModel(now:)`.
@MainActor
final class FocusLayoutWiringTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 100_000)

    // MARK: Settings

    func testFreshStoreDefaultsToStandard() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettings(fileURL: directory.appending(path: "settings.json"))

        try await store.load()

        XCTAssertEqual(store.popoverLayout, .standard)
        XCTAssertEqual(AppSettingsData().popoverLayout, .standard)
    }

    func testUnknownOrMissingValueDecodesToStandardWithoutLosingOtherFields() throws {
        let unknown = Data(#"{"popoverLayout":"cosy","sortByWeeklyReset":false}"#.utf8)
        let decoded = try JSONDecoder().decode(AppSettingsData.self, from: unknown)
        XCTAssertEqual(decoded.popoverLayout, .standard)
        XCTAssertFalse(decoded.sortByWeeklyReset)

        let wrongType = Data(#"{"popoverLayout":7}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(AppSettingsData.self, from: wrongType).popoverLayout, .standard)

        let missing = Data("{}".utf8)
        XCTAssertEqual(try JSONDecoder().decode(AppSettingsData.self, from: missing).popoverLayout, .standard)
    }

    func testSettingFocusPersistsAndReloads() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let store = AppSettings(fileURL: fileURL)
        try await store.load()

        try await store.setPopoverLayout(.focus)

        XCTAssertEqual(store.popoverLayout, .focus)
        XCTAssertEqual(store.data.popoverLayout, .focus)
        let restored = AppSettings(fileURL: fileURL)
        try await restored.load()
        XCTAssertEqual(restored.popoverLayout, .focus)
    }

    func testDataRoundTrip() throws {
        var data = AppSettingsData()
        data.popoverLayout = .focus
        let encoded = try JSONEncoder().encode(data)
        XCTAssertEqual(try JSONDecoder().decode(AppSettingsData.self, from: encoded), data)
    }

    func testLayoutPickerWritesThroughItsCallback() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettings(fileURL: directory.appending(path: "settings.json"))
        try await store.load()
        var written: [PopoverLayout] = []

        let binding = GeneralDetailView.layoutBinding(settings: store) { written.append($0) }
        XCTAssertEqual(binding.wrappedValue, .standard)
        binding.wrappedValue = .focus

        XCTAssertEqual(written, [.focus])
        XCTAssertEqual(PopoverLayout.allCases.map(\.title), ["Standard", "Focus"])
    }

    func testAppModelSetterPersists() async throws {
        let fixture = try makeAlertsFixture(now: { [t0] in t0 })
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        try await fixture.model.setPopoverLayout(.focus)

        XCTAssertEqual(fixture.model.settings.popoverLayout, .focus)
    }

    // MARK: Header switch

    func testHeaderSwitchBindingWritesThroughItsCallback() {
        for layout in PopoverLayout.allCases {
            var written: [PopoverLayout] = []
            let binding = MenuBarView.layoutBinding(layout: layout) { written.append($0) }
            XCTAssertEqual(binding.wrappedValue, layout)
            let other: PopoverLayout = layout == .standard ? .focus : .standard
            binding.wrappedValue = other
            XCTAssertEqual(written, [other], "\(layout)")
        }
    }

    func testHeaderSwitchPersistsTheSameSettingAsTheSettingsPicker() async throws {
        let fixture = try makeAlertsFixture(now: { [t0] in t0 })
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)

        await MenuBarContent.setLayout(.focus, model: fixture.model)
        XCTAssertEqual(fixture.model.settings.popoverLayout, .focus)
        let reloaded = AppSettings(fileURL: fixture.directory.appending(path: "app-settings.json"))
        try await reloaded.load()
        XCTAssertEqual(reloaded.popoverLayout, .focus)

        await MenuBarContent.setLayout(.standard, model: fixture.model)
        XCTAssertEqual(fixture.model.settings.popoverLayout, .standard)
        XCTAssertNil(fixture.model.errorMessage)
    }

    // MARK: Picked hero

    func testPickedHeroLastsUntilTheSurfaceIsPresentedAgain() {
        let surface = AccountPinSnapshot()
        let id = UUID()
        surface.pinFocusHero(id)
        XCTAssertEqual(surface.focusHeroID, id)
        surface.pinFocusHero(nil)
        XCTAssertNil(surface.focusHeroID)

        surface.pinFocusHero(id)
        // Every presentation captures the surface afresh → automatic hero.
        surface.refresh(from: [:], accounts: [])
        XCTAssertNil(surface.focusHeroID)
    }

    // MARK: AppModel.focusModel

    func testFocusModelUsesPerAccountPhasesAndHidesPausedAccounts() async throws {
        let fixture = try makeAlertsFixture(now: { [t0] in t0 })
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let a = try await signIn(fixture, label: "A")
        let b = try await signIn(fixture, label: "B")
        let c = try await signIn(fixture, label: "C")

        // A and B both burn (two same-provider accounts in use); C is paused.
        for (account, remaining) in [(a, 0.20), (b, 0.60)] {
            let before = snapshot(account.id, at: t0.addingTimeInterval(-300), fiveHour: remaining + 0.10)
            fixture.model.history.record(account: account, snapshot: before)
            let after = snapshot(account.id, at: t0, fiveHour: remaining)
            fixture.model.history.record(account: account, snapshot: after)
            try await fixture.snapshots.save(after)
        }
        try await fixture.model.setPaused(accountID: c.id, paused: true)

        let focus = fixture.model.focusModel(now: t0)

        XCTAssertEqual(focus.hero?.account.id, a.id)
        XCTAssertEqual(focus.hero?.isInUse, true)
        XCTAssertEqual(focus.otherInUse.map(\.account.id), [b.id])
        // Paused C is hidden in Focus.
        XCTAssertTrue(focus.others.isEmpty)
    }

    func testInUseDetectionOffDropsTagsAndHeroFallsBackToLeastHeadroom() async throws {
        let fixture = try makeAlertsFixture(now: { [t0] in t0 })
        defer { fixture.removeFiles() }
        try await fixture.model.load(startBackgroundRefresh: false)
        let a = try await signIn(fixture, label: "A")
        let b = try await signIn(fixture, label: "B")
        // A burns (in use) with plenty of headroom; B is idle and nearly spent.
        let before = snapshot(a.id, at: t0.addingTimeInterval(-300), fiveHour: 0.80)
        fixture.model.history.record(account: a, snapshot: before)
        let after = snapshot(a.id, at: t0, fiveHour: 0.70)
        fixture.model.history.record(account: a, snapshot: after)
        try await fixture.snapshots.save(after)
        try await fixture.snapshots.save(snapshot(b.id, at: t0, fiveHour: 0.10))
        XCTAssertEqual(fixture.model.focusModel(now: t0).hero?.account.id, a.id, "premise: in-use hero")
        XCTAssertEqual(fixture.model.focusModel(now: t0).hero?.isInUse, true)

        try await fixture.model.setFeature(.inUse, enabled: false)

        let focus = fixture.model.focusModel(now: t0)
        XCTAssertEqual(focus.hero?.account.id, b.id)
        XCTAssertEqual(focus.hero?.tag, FocusModel.Hero.Tag.none)
        XCTAssertTrue(focus.otherInUse.isEmpty)

        try await fixture.model.setFeature(.inUse, enabled: true)
        XCTAssertEqual(fixture.model.focusModel(now: t0).hero?.account.id, a.id)
    }

    // MARK: Helpers

    private func signIn(_ fixture: AlertsFixture, label: String) async throws -> AccountRecord {
        let sessionID = try fixture.model.beginSignIn(provider: .claude)
        try await fixture.model.completeSignIn(sessionID: sessionID, label: label)
        return try XCTUnwrap(fixture.model.accounts.first { $0.label == label })
    }

    private func snapshot(_ accountID: UUID, at date: Date, fiveHour: Double) -> UsageSnapshot {
        UsageSnapshot(
            accountID: accountID,
            fetchedAt: date,
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: fiveHour, resetsAt: nil),
            weekly: nil
        )
    }
}
