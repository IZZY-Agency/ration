import Foundation
import XCTest
@testable import Ration

@MainActor
final class AppSettingsTests: XCTestCase {
    func testFreshStoreDefaultsSortByWeeklyResetToTrue() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let store = AppSettings(fileURL: fileURL)

        try await store.load()

        XCTAssertTrue(store.sortByWeeklyReset)
    }

    func testSettingSortByWeeklyResetPersistsAndReloads() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let store = AppSettings(fileURL: fileURL)
        try await store.load()

        try await store.setSortByWeeklyReset(false)

        XCTAssertFalse(store.sortByWeeklyReset)

        let restored = AppSettings(fileURL: fileURL)
        try await restored.load()

        XCTAssertFalse(restored.sortByWeeklyReset)
    }

    func testFileMissingSortByWeeklyResetKeyDefaultsToTrue() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let json = Data("{}".utf8)
        try json.write(to: fileURL)
        let store = AppSettings(fileURL: fileURL)

        try await store.load()

        XCTAssertTrue(store.sortByWeeklyReset)
    }

    func testCorruptFileDefaultsToTrueWithoutThrowing() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let malformedJSON = Data("{ not valid json".utf8)
        try malformedJSON.write(to: fileURL)
        let store = AppSettings(fileURL: fileURL)

        // Should not throw
        try await store.load()

        XCTAssertTrue(store.sortByWeeklyReset)
        XCTAssertFalse(store.usageAlertsEnabled)
    }

    func testFreshStoreDefaultsUsageAlertsEnabledToFalse() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let store = AppSettings(fileURL: fileURL)

        try await store.load()

        XCTAssertFalse(store.usageAlertsEnabled)
    }

    func testSettingUsageAlertsEnabledPersistsAndReloads() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let store = AppSettings(fileURL: fileURL)
        try await store.load()

        try await store.setUsageAlertsEnabled(true)

        XCTAssertTrue(store.usageAlertsEnabled)

        let restored = AppSettings(fileURL: fileURL)
        try await restored.load()

        XCTAssertTrue(restored.usageAlertsEnabled)
    }

    /// Regression guard: each setter must preserve the OTHER field's current
    /// value when building its candidate `AppSettingsData`, not silently
    /// reset it to that struct's default.
    func testSettingOneFieldDoesNotClobberTheOther() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let store = AppSettings(fileURL: fileURL)
        try await store.load()

        try await store.setUsageAlertsEnabled(true)
        try await store.setSortByWeeklyReset(false)

        XCTAssertFalse(store.sortByWeeklyReset)
        XCTAssertTrue(store.usageAlertsEnabled, "toggling sort must not reset usageAlertsEnabled")

        let restored = AppSettings(fileURL: fileURL)
        try await restored.load()

        XCTAssertFalse(restored.sortByWeeklyReset)
        XCTAssertTrue(restored.usageAlertsEnabled)
    }

    func testFreshStoreDefaultsShowInUseInMenuBarToTrue() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettings(fileURL: directory.appending(path: "settings.json"))

        try await store.load()

        XCTAssertTrue(store.showInUseInMenuBar)
    }

    func testFileMissingShowInUseInMenuBarKeyDefaultsToTrue() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        // A settings.json written by an older build: no menu-bar key at all.
        try Data(#"{"sortByWeeklyReset":false}"#.utf8).write(to: fileURL)
        let store = AppSettings(fileURL: fileURL)

        try await store.load()

        XCTAssertTrue(store.showInUseInMenuBar)
        XCTAssertFalse(store.loadFailed)
    }

    func testSettingShowInUseInMenuBarPersistsAndReloads() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let store = AppSettings(fileURL: fileURL)
        try await store.load()

        try await store.setShowInUseInMenuBar(false)

        XCTAssertFalse(store.showInUseInMenuBar)

        let restored = AppSettings(fileURL: fileURL)
        try await restored.load()

        XCTAssertFalse(restored.showInUseInMenuBar)
    }

    func testMenuBarWindowDefaultsPerProvider() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettings(fileURL: directory.appending(path: "settings.json"))

        try await store.load()

        XCTAssertEqual(store.menuBarWindow(for: .claude), .fiveHour)
        XCTAssertEqual(store.menuBarWindow(for: .chatGPT), .weekly)
        XCTAssertFalse(store.menuBarDisplaysRemaining)
    }

    func testMenuBarWindowSelectionPersistsAndReloads() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let store = AppSettings(fileURL: fileURL)
        try await store.load()

        try await store.setMenuBarWindow(.modelWeekly, for: .claude)
        try await store.setMenuBarDisplaysRemaining(true)

        XCTAssertEqual(store.menuBarWindow(for: .claude), .modelWeekly)
        XCTAssertTrue(store.menuBarDisplaysRemaining)

        let restored = AppSettings(fileURL: fileURL)
        try await restored.load()

        XCTAssertEqual(restored.menuBarWindow(for: .claude), .modelWeekly)
        // Unset providers keep their defaults.
        XCTAssertEqual(restored.menuBarWindow(for: .chatGPT), .weekly)
        XCTAssertTrue(restored.menuBarDisplaysRemaining)
    }

    func testMenuBarFieldsMissingFromLegacyFileFallBackToDefaults() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        // A settings.json written by 0.24.0: menu-bar toggle only.
        try Data(#"{"showInUseInMenuBar":false}"#.utf8).write(to: fileURL)
        let store = AppSettings(fileURL: fileURL)

        try await store.load()

        XCTAssertFalse(store.showInUseInMenuBar)
        XCTAssertEqual(store.menuBarWindow(for: .claude), .fiveHour)
        XCTAssertFalse(store.menuBarDisplaysRemaining)
        XCTAssertFalse(store.loadFailed)
    }

    func testMenuBarWindowUnknownRawValueFallsBackToDefault() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        // A hand-edited/corrupted kind must not crash or stick.
        try Data(#"{"menuBarWindows":{"claude":"nonsense"}}"#.utf8).write(to: fileURL)
        let store = AppSettings(fileURL: fileURL)

        try await store.load()

        XCTAssertEqual(store.menuBarWindow(for: .claude), .fiveHour)
        XCTAssertFalse(store.loadFailed)
    }

    func testFreshStoreDefaultsHasCompletedOnboardingToFalse() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettings(fileURL: directory.appending(path: "settings.json"))

        try await store.load()

        XCTAssertFalse(store.hasCompletedOnboarding)
    }

    func testFileMissingHasCompletedOnboardingKeyDefaultsToFalse() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        // A settings.json written by an older build: no onboarding key at all.
        try Data(#"{"sortByWeeklyReset":false}"#.utf8).write(to: fileURL)
        let store = AppSettings(fileURL: fileURL)

        try await store.load()

        XCTAssertFalse(store.hasCompletedOnboarding)
        XCTAssertFalse(store.sortByWeeklyReset)
        XCTAssertFalse(store.loadFailed)
    }

    func testSettingHasCompletedOnboardingPersistsAndReloads() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let store = AppSettings(fileURL: fileURL)
        try await store.load()

        try await store.setHasCompletedOnboarding(true)

        XCTAssertTrue(store.hasCompletedOnboarding)

        let restored = AppSettings(fileURL: fileURL)
        try await restored.load()

        XCTAssertTrue(restored.hasCompletedOnboarding)
    }

    func testSettingHasCompletedOnboardingPreservesOtherFields() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let store = AppSettings(fileURL: fileURL)
        try await store.load()
        try await store.setSortByWeeklyReset(false)
        try await store.setUsageAlertsEnabled(true)

        try await store.setHasCompletedOnboarding(true)

        XCTAssertFalse(store.sortByWeeklyReset)
        XCTAssertTrue(store.usageAlertsEnabled)
        XCTAssertTrue(store.hasCompletedOnboarding)
    }

    func testCorruptFileLeavesOnboardingIncompleteAndRecordsLoadFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        try Data("{ not json".utf8).write(to: fileURL)
        let store = AppSettings(fileURL: fileURL)

        try await store.load()

        // Both halves matter: the substituted default is `false`, and
        // `loadFailed` is what stops that default from being read as consent to
        // re-present the wizard.
        XCTAssertFalse(store.hasCompletedOnboarding)
        XCTAssertTrue(store.loadFailed)
    }

    func testLegacyFileWithoutThresholdsDecodesToDefaults() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        // A settings file as written by 0.26.x — no threshold keys at all.
        try Data(#"{"sortByWeeklyReset":true,"usageAlertsEnabled":true}"#.utf8)
            .write(to: fileURL)

        let store = AppSettings(fileURL: fileURL)
        try await store.load()

        XCTAssertFalse(store.loadFailed)
        XCTAssertTrue(store.usageAlertsEnabled)
        let pair = store.data.thresholds(provider: .claude, window: .fiveHour)
        XCTAssertEqual(pair, .default)
        XCTAssertEqual(store.data.cursorSpend, .off)
        // A legacy file names no channels, so every cell resolves to the
        // default — which since 0.28.0 includes the drop. An upgrading user
        // who never configured channels therefore GAINS the panel; that is
        // intended, not incidental (see `AlertChannels.default`).
        XCTAssertEqual(
            store.data.channels(forKey: AppSettingsData.thresholdKey(provider: .claude, window: .weekly)),
            .default
        )
    }

    func testThresholdKeyIsProviderDotWindow() {
        XCTAssertEqual(
            AppSettingsData.thresholdKey(provider: .claude, window: .modelWeekly),
            "claude.modelWeekly"
        )
        XCTAssertEqual(
            AppSettingsData.thresholdKey(provider: .chatGPT, window: .weekly),
            "chatgpt.weekly"
        )
        XCTAssertEqual(AppSettingsData.cursorSpendKey, "cursor.spend")
    }

    func testConfiguredThresholdIsReadBack() {
        let key = AppSettingsData.thresholdKey(provider: .claude, window: .fiveHour)
        let data = AppSettingsData(
            alertThresholds: [key: ThresholdPair(warningPercent: 60, criticalPercent: 80)]
        )
        XCTAssertEqual(data.thresholds(provider: .claude, window: .fiveHour).warningPercent, 60)
        // A window with no configured entry still falls back.
        XCTAssertEqual(data.thresholds(provider: .claude, window: .weekly), .default)
    }

    // The whole point of per-entry decoding: one malformed threshold must not
    // take the user's unrelated settings down with it.
    func testMalformedThresholdEntryDoesNotResetOtherSettings() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        try Data(#"""
        {"sortByWeeklyReset":false,"quietHours":[5],
         "alertThresholds":{"claude.fiveHour":"not-an-object",
                            "claude.weekly":{"warningPercent":50,"criticalPercent":70}}}
        """#.utf8).write(to: fileURL)

        let store = AppSettings(fileURL: fileURL)
        try await store.load()

        XCTAssertFalse(store.loadFailed)
        XCTAssertFalse(store.sortByWeeklyReset)
        XCTAssertEqual(store.quietHours, [5])
        // The malformed entry falls back...
        XCTAssertEqual(store.data.thresholds(provider: .claude, window: .fiveHour), .default)
        // ...and its well-formed sibling survives.
        XCTAssertEqual(
            store.data.thresholds(provider: .claude, window: .weekly).warningPercent,
            50
        )
    }

    func testUnknownProviderKeyIsIgnored() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        try Data(#"{"alertThresholds":{"llama.fiveHour":{"warningPercent":10,"criticalPercent":20}}}"#.utf8)
            .write(to: fileURL)

        let store = AppSettings(fileURL: fileURL)
        try await store.load()

        XCTAssertFalse(store.loadFailed)
        XCTAssertEqual(store.data.thresholds(provider: .claude, window: .fiveHour), .default)
    }

    // A channels entry whose array holds a non-string element makes
    // `AlertChannels` throw typeMismatch. Per-entry decoding must contain that
    // throw: the bad entry is dropped and its cell falls back to the default,
    // rather than the failure escaping and resetting every setting.
    func testMalformedChannelsEntryFallsBackWithoutLosingOtherSettings() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        try Data(#"{"sortByWeeklyReset":false,"alertChannels":{"claude.weekly":[5]}}"#.utf8)
            .write(to: fileURL)

        let store = AppSettings(fileURL: fileURL)
        try await store.load()

        XCTAssertFalse(store.loadFailed)
        XCTAssertFalse(store.sortByWeeklyReset)
        // The malformed entry is dropped, so this cell falls back to the
        // default rather than keeping a half-decoded value.
        XCTAssertEqual(
            store.data.channels(forKey: AppSettingsData.thresholdKey(provider: .claude, window: .weekly)),
            .default
        )
    }

    func testSettingThresholdPersistsAndReloads() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let store = AppSettings(fileURL: fileURL)
        try await store.load()

        try await store.setThresholds(
            ThresholdPair(warningPercent: 60, criticalPercent: 85),
            provider: .claude,
            window: .fiveHour
        )

        let restored = AppSettings(fileURL: fileURL)
        try await restored.load()
        let pair = restored.data.thresholds(provider: .claude, window: .fiveHour)
        XCTAssertEqual(pair.warningPercent, 60)
        XCTAssertEqual(pair.criticalPercent, 85)
        // Untouched cells stay at the default.
        XCTAssertEqual(restored.data.thresholds(provider: .chatGPT, window: .weekly), .default)
    }

    func testSettingThresholdCanonicalisesBeforePersisting() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettings(fileURL: directory.appending(path: "settings.json"))
        try await store.load()

        try await store.setThresholds(
            ThresholdPair(warningPercent: 99, criticalPercent: 50),
            provider: .claude,
            window: .weekly
        )

        let pair = store.data.thresholds(provider: .claude, window: .weekly)
        XCTAssertEqual(pair.criticalPercent, 50)
        XCTAssertEqual(pair.warningPercent, 49)
    }

    /// Pins the fix for the whole-pair race: a UI that commits one field at a
    /// time (`AlertsDetailView.ThresholdFieldsRow`, on blur) must not have a
    /// second field's commit carry a stale sibling value back over an edit
    /// that hasn't round-tripped yet. `setWarningPercent`/`setCriticalPercent`
    /// each read the FRESHEST stored pair from inside `mutate`'s serialized
    /// queue rather than composing from a value the caller held locally, so
    /// firing both without awaiting the first must still land both edits —
    /// whichever runs second reads the first's already-applied result.
    func testFieldLevelThresholdEditsDoNotRaceEachOther() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettings(fileURL: directory.appending(path: "settings.json"))
        try await store.load()

        // Fired back-to-back WITHOUT awaiting the first — exactly the shape
        // of blurring Warn then immediately blurring Crit before the first
        // save has round-tripped.
        async let warning: Void = store.setWarningPercent(60, provider: .claude, window: .fiveHour)
        async let critical: Void = store.setCriticalPercent(95, provider: .claude, window: .fiveHour)
        _ = try await (warning, critical)

        let pair = store.data.thresholds(provider: .claude, window: .fiveHour)
        XCTAssertEqual(pair.warningPercent, 60)
        XCTAssertEqual(pair.criticalPercent, 95)
    }

    func testSettingCursorSpendPersists() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let store = AppSettings(fileURL: fileURL)
        try await store.load()

        try await store.setCursorSpend(
            SpendThresholds(warningCents: 5_000, criticalCents: 8_000)
        )

        let restored = AppSettings(fileURL: fileURL)
        try await restored.load()
        XCTAssertEqual(restored.cursorSpend.warningCents, 5_000)
        XCTAssertEqual(restored.cursorSpend.criticalCents, 8_000)
    }

    // MARK: - Drop channel

    /// Field-level, like the threshold percents: `notification` and `drop` are
    /// two fields of ONE stored value, so composing a whole `AlertChannels`
    /// from a locally-held copy would let one checkbox's commit carry a stale
    /// sibling back over the other's.
    func testSettingTheDropChannelPreservesTheNotificationChannel() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettings(fileURL: directory.appending(path: "settings.json"))
        try await store.load()
        let key = AppSettingsData.thresholdKey(provider: .claude, window: .weekly)

        // Start from notification OFF — the default has it ON, and against
        // that starting point "preserve the sibling" and "hardcode true" are
        // indistinguishable, so the test would pass against a clobbering
        // implementation. (It did: the first version of this test survived
        // exactly that mutation.)
        try await store.setChannels(AlertChannels(notification: false, drop: false), forKey: key)

        try await store.setDropEnabled(true, forKey: key)
        let on = store.data.channels(forKey: key)
        XCTAssertTrue(on.drop)
        XCTAssertFalse(
            on.notification,
            "toggling the drop must carry the sibling through, not reset it to the default"
        )

        try await store.setDropEnabled(false, forKey: key)
        let off = store.data.channels(forKey: key)
        XCTAssertFalse(off.drop)
        XCTAssertFalse(off.notification, "still preserved on the way back")
    }

    /// Mirror of the drop test, from the opposite starting point for the same
    /// discrimination reason.
    func testSettingTheNotificationChannelPreservesTheDropChannel() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettings(fileURL: directory.appending(path: "settings.json"))
        try await store.load()
        let key = AppSettingsData.thresholdKey(provider: .claude, window: .weekly)

        try await store.setChannels(AlertChannels(notification: true, drop: false), forKey: key)

        try await store.setNotificationEnabled(false, forKey: key)
        let off = store.data.channels(forKey: key)
        XCTAssertFalse(off.notification)
        XCTAssertFalse(off.drop, "toggling notifications must not resurrect the drop")
    }

    func testDropChannelPersists() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appending(path: "settings.json")
        let key = AppSettingsData.thresholdKey(provider: .claude, window: .weekly)

        let store = AppSettings(fileURL: fileURL)
        try await store.load()
        try await store.setDropEnabled(false, forKey: key)

        let reloaded = AppSettings(fileURL: fileURL)
        try await reloaded.load()
        let back = reloaded.data.channels(forKey: key)
        XCTAssertFalse(back.drop)
        XCTAssertTrue(back.notification)
    }

    /// Cursor's spend row has its own channel entry, keyed separately from any
    /// provider x window cell.
    func testCursorSpendHasItsOwnDropChannelEntry() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppSettings(fileURL: directory.appending(path: "settings.json"))
        try await store.load()

        try await store.setDropEnabled(false, forKey: AppSettingsData.cursorSpendKey)
        let spend = store.data.channels(forKey: AppSettingsData.cursorSpendKey)
        let weekly = store.data.channels(
            forKey: AppSettingsData.thresholdKey(provider: .claude, window: .weekly)
        )
        XCTAssertFalse(spend.drop)
        XCTAssertTrue(weekly.drop, "the spend row must not share a channel entry with a rate window")
    }
}

/// Quiet-hours / holidays persistence, plus guards for the mutate-a-copy
/// setter refactor they motivated.
@MainActor
final class AppSettingsQuietHoursTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appending(path: "settings-\(UUID().uuidString).json")
    }

    func testLegacyFileWithoutKeysDecodesToEmpty() throws {
        let legacy = #"{"sortByWeeklyReset":true,"usageAlertsEnabled":true}"#.data(using: .utf8)!
        let data = try JSONDecoder().decode(AppSettingsData.self, from: legacy)
        XCTAssertEqual(data.quietHours, [])
        XCTAssertEqual(data.holidays, [])
        XCTAssertTrue(data.usageAlertsEnabled) // untouched
    }

    func testDecodeCanonicalizesCells() throws {
        // out-of-range dropped, duplicates removed, result sorted
        let raw = #"{"quietHours":[200,5,5,-1,3,167]}"#.data(using: .utf8)!
        let data = try JSONDecoder().decode(AppSettingsData.self, from: raw)
        XCTAssertEqual(data.quietHours, [3, 5, 167])
    }

    func testQuietHoursRoundTrip() async throws {
        let url = tempURL()
        let settings = AppSettings(fileURL: url)
        try await settings.setQuietHours([24, 3, 3])
        XCTAssertEqual(settings.quietHours, [3, 24]) // canonical on write too

        let reloaded = AppSettings(fileURL: url)
        try await reloaded.load()
        XCTAssertEqual(reloaded.quietHours, [3, 24])
    }

    func testHolidaysRoundTrip() async throws {
        let url = tempURL()
        let settings = AppSettings(fileURL: url)
        let holiday = HolidayRange(
            start: LocalDate(year: 2026, month: 8, day: 1),
            end: LocalDate(year: 2026, month: 8, day: 14),
            label: "Vacation"
        )
        try await settings.setHolidays([holiday])

        let reloaded = AppSettings(fileURL: url)
        try await reloaded.load()
        XCTAssertEqual(reloaded.holidays, [holiday])
    }

    /// Guards the mutate-a-copy refactor: a setter must not revert other fields.
    func testSettersPreserveOtherFields() async throws {
        let settings = AppSettings(fileURL: tempURL())
        try await settings.setUsageAlertsEnabled(true)
        try await settings.setSortByWeeklyReset(false)
        try await settings.setQuietHours([1])
        try await settings.setHolidays([
            HolidayRange(
                start: LocalDate(year: 2026, month: 1, day: 1),
                end: LocalDate(year: 2026, month: 1, day: 2),
                label: "NY"
            )
        ])
        XCTAssertTrue(settings.usageAlertsEnabled)
        XCTAssertFalse(settings.sortByWeeklyReset)
        XCTAssertEqual(settings.quietHours, [1])
        XCTAssertEqual(settings.holidays.count, 1)
    }

    /// Genuinely CONCURRENT setters: the first save is held OPEN until the test
    /// confirms it actually entered the gate, so the second setter is
    /// guaranteed to be queued behind an in-flight save. That is the only
    /// arrangement that proves the candidate is built inside `mutations.run` —
    /// releasing the gate immediately would let the test pass without ever
    /// suspending anything.
    func testConcurrentSettersDoNotClobber() async throws {
        let gate = AsyncGate()
        let entered = AsyncSignal()
        let counter = SaveCounter()
        let settings = AppSettings(fileURL: tempURL()) { _ in
            if await counter.isFirst() {
                await entered.signal()
                await gate.wait()
            }
        }
        async let first: Void = settings.setUsageAlertsEnabled(true)
        // Do not release until the first save is provably suspended in the gate.
        await entered.wait()
        async let second: Void = settings.setQuietHours([7])
        await gate.open()
        _ = try await (first, second)
        XCTAssertTrue(settings.usageAlertsEnabled)
        XCTAssertEqual(settings.quietHours, [7])
    }

    func testHolidayDeltasComposeInsteadOfClobbering() async throws {
        let settings = AppSettings(fileURL: tempURL())
        let a = HolidayRange(
            start: LocalDate(year: 2026, month: 8, day: 1),
            end: LocalDate(year: 2026, month: 8, day: 2),
            label: "A"
        )
        let b = HolidayRange(
            start: LocalDate(year: 2026, month: 9, day: 1),
            end: LocalDate(year: 2026, month: 9, day: 2),
            label: "B"
        )
        // Concurrent adds must both survive: each delta is applied to the
        // freshest snapshot inside the serialized mutation, not to a stale
        // published array.
        async let first: Void = settings.addHoliday(a)
        async let second: Void = settings.addHoliday(b)
        _ = try await (first, second)
        XCTAssertEqual(Set(settings.holidays.map(\.label)), ["A", "B"])

        try await settings.setHolidayLabel(id: a.id, "A2")
        XCTAssertEqual(settings.holidays.count, 2)
        XCTAssertEqual(settings.holidays.first { $0.id == a.id }?.label, "A2")

        try await settings.removeHoliday(id: b.id)
        XCTAssertEqual(settings.holidays.map(\.id), [a.id])
    }

    /// Field-specific deltas on the SAME row must compose: a label edit and a
    /// date edit issued together must both land, not overwrite each other.
    func testSameRowFieldDeltasCompose() async throws {
        let settings = AppSettings(fileURL: tempURL())
        let h = HolidayRange(
            start: LocalDate(year: 2026, month: 8, day: 1),
            end: LocalDate(year: 2026, month: 8, day: 2),
            label: "Old"
        )
        try await settings.addHoliday(h)
        async let a: Void = settings.setHolidayLabel(id: h.id, "New")
        async let b: Void = settings.setHolidayEnd(id: h.id, LocalDate(year: 2026, month: 8, day: 10))
        _ = try await (a, b)
        let saved = settings.holidays.first { $0.id == h.id }
        XCTAssertEqual(saved?.label, "New")
        XCTAssertEqual(saved?.end, LocalDate(year: 2026, month: 8, day: 10))
        XCTAssertEqual(saved?.start, LocalDate(year: 2026, month: 8, day: 1)) // untouched
    }

    func testHolidayDateClampingInStore() async throws {
        let settings = AppSettings(fileURL: tempURL())
        let h = HolidayRange(
            start: LocalDate(year: 2026, month: 8, day: 10),
            end: LocalDate(year: 2026, month: 8, day: 12),
            label: "X"
        )
        try await settings.addHoliday(h)
        // Push start past end → end clamps up to start.
        try await settings.setHolidayStart(id: h.id, LocalDate(year: 2026, month: 8, day: 20))
        var saved = settings.holidays.first { $0.id == h.id }
        XCTAssertEqual(saved?.start, LocalDate(year: 2026, month: 8, day: 20))
        XCTAssertEqual(saved?.end, LocalDate(year: 2026, month: 8, day: 20))
        // Pull end before start → start clamps down to end.
        try await settings.setHolidayEnd(id: h.id, LocalDate(year: 2026, month: 8, day: 5))
        saved = settings.holidays.first { $0.id == h.id }
        XCTAssertEqual(saved?.start, LocalDate(year: 2026, month: 8, day: 5))
        XCTAssertEqual(saved?.end, LocalDate(year: 2026, month: 8, day: 5))
    }
}

/// One-shot signal: lets a test wait until a held effect has actually started.
actor AsyncSignal {
    private var continuation: CheckedContinuation<Void, Never>?
    private var didSignal = false

    func signal() {
        didSignal = true
        continuation?.resume()
        continuation = nil
    }

    func wait() async {
        if didSignal { return }
        await withCheckedContinuation { continuation = $0 }
    }
}

/// Minimal one-shot gate so a test can hold a save open.
actor AsyncGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}

/// Tracks whether a save is the first one, off the main actor.
actor SaveCounter {
    private var count = 0

    func isFirst() -> Bool {
        count += 1
        return count == 1
    }
}
