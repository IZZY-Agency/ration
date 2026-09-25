import XCTest
@testable import Ration

/// Review Focus 5: nothing the app persists depends on the UI language.
///
/// Each test writes `app-settings.json` / `alert-state.json` /
/// `snapshots.json` through the real stores (`AppSettings`,
/// `AlertStateStore`, `UsageSnapshotStore` → `JSONFileStore`) and
/// compares the file's bytes with ONE fixed golden string. The class runs in
/// the pinned English `unit-test` and in `l10n-test L10N_LANG=fr|uk`, so the
/// same golden passing in all three runs proves the bytes written under fr
/// and uk equal the bytes written under en. The goldens are the bytes 1.3.0's encoders write for these
/// fixtures (captured from the English run); a new persisted field changes
/// them in every language at once.
@MainActor
final class PersistedStateLocalizationTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "PersistedStateLocalizationTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: app-settings.json

    static let settingsGolden = #"{"alertChannels":{"claude.weekly":["notification"]},"alertThresholds":{"claude.fiveHour":{"criticalPercent":95,"warningPercent":60}},"cursorSpend":{"criticalCents":5000,"warningCents":2500},"dropSnoozed":false,"featureInUseEnabled":true,"featureResetsEnabled":true,"featureSwitchAdviceEnabled":true,"featureWarmUpEnabled":false,"hasCompletedOnboarding":true,"holidays":[{"end":"2027-01-02","id":"6F1C1A52-0000-4000-8000-000000000001","label":"Winter break","start":"2026-12-24"}],"menuBarDisplaysRemaining":true,"menuBarWindows":{"chatgpt":"weekly"},"popoverLayout":"focus","quietHours":[0,1,2],"redactNotifications":true,"resetExpiryLeadDays":{"chatgpt":3},"showInUseInMenuBar":true,"sortByWeeklyReset":false,"usageAlertsEnabled":true}"#

    func testSettingsFileIsTheSameBytesInEveryLanguage() async throws {
        let fileURL = directory.appending(path: "app-settings.json")
        let settings = AppSettings(fileURL: fileURL)
        try await settings.load()
        try await settings.setSortByWeeklyReset(false)
        try await settings.setUsageAlertsEnabled(true)
        try await settings.setRedactNotifications(true)
        try await settings.setQuietHours([2, 1, 0])
        let holiday = HolidayRange(
            id: UUID(uuidString: "6F1C1A52-0000-4000-8000-000000000001")!,
            start: LocalDate(year: 2026, month: 12, day: 24),
            end: LocalDate(year: 2027, month: 1, day: 2),
            label: "Winter break"
        )
        try await settings.setHolidays([holiday])
        try await settings.setHasCompletedOnboarding(true)
        try await settings.setMenuBarWindow(.weekly, for: .chatGPT)
        try await settings.setMenuBarDisplaysRemaining(true)
        try await settings.setThresholds(
            ThresholdPair(warningPercent: 60, criticalPercent: 95),
            provider: .claude,
            window: .fiveHour
        )
        try await settings.setChannels(
            .notificationOnly,
            forKey: AppSettingsData.thresholdKey(provider: .claude, window: .weekly)
        )
        try await settings.setCursorSpend(SpendThresholds(warningCents: 2_500, criticalCents: 5_000))
        try await settings.setResetExpiryLeadDays(3, provider: .chatGPT)
        try await settings.setPopoverLayout(.focus)
        try await settings.setFeature(.warmUp, enabled: false)

        let written = try String(decoding: Data(contentsOf: fileURL), as: UTF8.self)
        XCTAssertEqual(written, Self.settingsGolden)

    }

    // MARK: alert-state.json

    static let alertStateGolden = #"["1D0E0E0E-0000-4000-8000-000000000002",{"fiveHour":{"hasObserved":true,"identity":"1970-01-12T14:46:40Z","lastRemaining":0.05,"notifiedTier":90},"modelWeekly":{"hasObserved":false},"notifiedRateLimited":false,"notifiedReauth":true,"resetCredits":{"credit-1":{"availableRow":"active","expiringRow":"inactive","expiryHandled":false,"lastSeenCount":1,"lastSeenExpiresAt":"1970-01-14T13:46:40Z"}},"spend":{"hasObserved":false},"weekly":{"hasObserved":true,"identity":"1970-01-19T13:46:40Z","lastRemaining":0.2,"notifiedTier":75}}]"#

    func testAlertStateFileIsTheSameBytesInEveryLanguage() async throws {
        let accountID = UUID(uuidString: "1D0E0E0E-0000-4000-8000-000000000002")!
        let now = Date(timeIntervalSince1970: 1_000_000)
        let credits = ResetCredits(
            fetchedAt: now,
            items: [
                ResetCredit(
                    id: "credit-1", title: "Weekly limit reset", count: 1,
                    expiresAt: now.addingTimeInterval(2 * 86_400), usableNow: true
                ),
            ],
            complete: true
        )
        let snapshot = UsageSnapshot(
            accountID: accountID,
            fetchedAt: now,
            fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.05, resetsAt: now.addingTimeInterval(3_600)),
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.2, resetsAt: now.addingTimeInterval(7 * 86_400)),
            resetCredits: credits
        )
        // Prime, then cross: the same two-pass sequence AppModel runs.
        let primed = AlertPolicy.evaluate(
            previous: AccountAlertState(),
            snapshot: UsageSnapshot(
                accountID: accountID, fetchedAt: now,
                fiveHour: UsageWindow(kind: .fiveHour, remainingFraction: 0.9, resetsAt: now.addingTimeInterval(3_600)),
                weekly: UsageWindow(kind: .weekly, remainingFraction: 0.9, resetsAt: now.addingTimeInterval(7 * 86_400))
            ),
            state: .current,
            thresholds: { _ in .default },
            spendThresholds: .off
        )
        let crossed = AlertPolicy.evaluate(
            previous: primed.next,
            snapshot: snapshot,
            state: .reauthenticationRequired,
            thresholds: { _ in .default },
            spendThresholds: .off,
            resetCredits: ResetCreditAlertInput(credits: credits, leadDays: 1, now: now)
        )
        XCTAssertFalse(crossed.events.isEmpty, "the fixture must fire events, or it proves nothing")

        let fileURL = directory.appending(path: "alert-state.json")
        let store = AlertStateStore(fileURL: fileURL)
        try await store.load()
        try await store.save(crossed.next, for: accountID)

        let written = try String(decoding: Data(contentsOf: fileURL), as: UTF8.self)
        XCTAssertEqual(written, Self.alertStateGolden)
    }

    // MARK: snapshots.json

    static let snapshotsGolden = #"["5A5A5A5A-0000-4000-8000-000000000003",{"accountID":"5A5A5A5A-0000-4000-8000-000000000003","cursorSpend":{"periodStart":"1970-01-11T10:00:00Z","planLabel":"Free","resetsAt":"1970-01-13T17:33:20Z","spentCents":1234},"fetchedAt":"1970-01-12T13:46:40Z","weekly":{"kind":"weekly","remainingFraction":0.5,"resetsAt":"1970-01-13T13:46:40Z"}}]"#

    /// `snapshots.json` is the one file that stores text a card shows: the
    /// Cursor plan tag (`CursorSpend.planLabel`, from
    /// `CursorProviderAdapter.label(for:)`). It must stay the provider's
    /// plan name in every language.
    func testSnapshotsFileIsTheSameBytesInEveryLanguage() async throws {
        let accountID = UUID(uuidString: "5A5A5A5A-0000-4000-8000-000000000003")!
        let now = Date(timeIntervalSince1970: 1_000_000)
        let body = #"{"membershipType":"free","isYearlyPlan":false,"periodStartMs":900000000,"periodEndMs":1100000000,"spentCents":1234}"#
        let spend = try await CursorProviderAdapter.parse(body)
        let snapshot = UsageSnapshot(
            accountID: accountID,
            fetchedAt: now,
            fiveHour: nil,
            weekly: UsageWindow(kind: .weekly, remainingFraction: 0.5, resetsAt: now.addingTimeInterval(86_400)),
            cursorSpend: spend
        )

        let fileURL = directory.appending(path: "snapshots.json")
        let store = UsageSnapshotStore(fileURL: fileURL)
        try await store.load()
        try await store.save(snapshot)

        let written = try String(decoding: Data(contentsOf: fileURL), as: UTF8.self)
        XCTAssertEqual(written, Self.snapshotsGolden)
    }
}
