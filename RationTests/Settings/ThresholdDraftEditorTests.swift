import XCTest
@testable import Ration

/// The Alerts pane's warning/critical rows: both fields commit as one
/// draft when focus leaves the row, and both are drawn from the pair the
/// store returned. Driven against a real `AppSettings` over a temporary file;
/// only its save can be held or failed.
@MainActor
final class ThresholdDraftEditorTests: XCTestCase {
    private var directory: URL!
    private var settings: AppSettings!
    private var disk: DiskGate!
    private var errors: [Error] = []
    private var clock: DebounceClock!

    private let provider = Provider.claude
    private let window = UsageWindowKind.fiveHour

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "settings.json")
        let fileStore = JSONFileStore<AppSettingsData>(
            fileURL: fileURL,
            defaultValue: AppSettingsData(sortByWeeklyReset: true)
        )
        let disk = DiskGate()
        self.disk = disk
        settings = AppSettings(fileURL: fileURL, saveSettings: { data in
            try await disk.save(data, to: fileStore)
        })
        try await settings.load()
        errors = []
        clock = DebounceClock()
    }

    override func tearDown() async throws {
        disk.releaseAll()
        clock.fire()
        try? FileManager.default.removeItem(at: directory)
    }

    private var storedPair: ThresholdPair {
        settings.data.thresholds(provider: provider, window: window)
    }

    private func percentEditor() -> ThresholdDraftEditor<ThresholdPair, Int> {
        let settings = settings!
        let clock = clock!
        let provider = provider
        let window = window
        return ThresholdDraftEditor.editor(
            key: "test",
            stored: storedPair,
            fields: ThresholdDraftFields.percent,
            sleep: { duration in try await clock.sleep(duration) },
            in: nil,
            commit: { warning, critical in
                try await settings.setThresholds(
                    warning: warning,
                    critical: critical,
                    provider: provider,
                    window: window
                )
            },
            onError: { [weak self] error in
                self?.errors.append(error)
            }
        )
    }

    private func spendEditor() -> ThresholdDraftEditor<SpendThresholds, Int?> {
        let settings = settings!
        let clock = clock!
        return ThresholdDraftEditor.editor(
            key: "test.spend",
            stored: settings.cursorSpend,
            fields: ThresholdDraftFields.cursorSpend,
            sleep: { duration in try await clock.sleep(duration) },
            in: nil,
            commit: { warning, critical in
                try await settings.setCursorSpend(warning: warning, critical: critical)
            },
            onError: { [weak self] error in
                self?.errors.append(error)
            }
        )
    }

    // MARK: one draft per row

    func testWarningThenCriticalGivesTheSamePairAsCriticalThenWarning() async {
        XCTAssertEqual(storedPair, ThresholdPair(warningPercent: 75, criticalPercent: 90))
        let editor = percentEditor()

        editor.focusChanged(to: .warning)
        editor.warningText = "95"
        editor.focusChanged(to: .critical)
        editor.criticalText = "99"
        editor.focusChanged(to: nil)
        await settle(editor)

        XCTAssertEqual(storedPair, ThresholdPair(warningPercent: 95, criticalPercent: 99))
        XCTAssertEqual(editor.warningText, "95")
        XCTAssertEqual(editor.criticalText, "99")
    }

    func testCriticalThenWarningGivesTheSamePairAsWarningThenCritical() async {
        let editor = percentEditor()

        editor.focusChanged(to: .critical)
        editor.criticalText = "99"
        editor.focusChanged(to: .warning)
        editor.warningText = "95"
        editor.focusChanged(to: nil)
        await settle(editor)

        XCTAssertEqual(storedPair, ThresholdPair(warningPercent: 95, criticalPercent: 99))
        XCTAssertEqual(editor.warningText, "95")
        XCTAssertEqual(editor.criticalText, "99")
    }

    func testMovingFocusBetweenTheRowsFieldsCommitsNothing() async {
        let editor = percentEditor()

        editor.focusChanged(to: .warning)
        editor.warningText = "95"
        editor.focusChanged(to: .critical)
        await drain()

        XCTAssertEqual(disk.saves.count, 0)
        XCTAssertEqual(storedPair, .default)
        XCTAssertTrue(editor.hasPendingEdit)
    }

    func testCursorSpendWarningThenCriticalKeepsBoth() async throws {
        try await settings.setCursorSpend(SpendThresholds(warningCents: 5_000, criticalCents: 8_000))
        let editor = spendEditor()

        editor.focusChanged(to: .warning)
        editor.warningText = "90"
        editor.focusChanged(to: .critical)
        editor.criticalText = "100"
        editor.focusChanged(to: nil)
        await settle(editor)

        XCTAssertEqual(settings.cursorSpend, SpendThresholds(warningCents: 9_000, criticalCents: 10_000))
        XCTAssertEqual(editor.warningText, "90.00")
        XCTAssertEqual(editor.criticalText, "100.00")
    }

    func testCursorSpendCriticalThenWarningKeepsBoth() async throws {
        try await settings.setCursorSpend(SpendThresholds(warningCents: 5_000, criticalCents: 8_000))
        let editor = spendEditor()

        editor.focusChanged(to: .critical)
        editor.criticalText = "100"
        editor.focusChanged(to: .warning)
        editor.warningText = "90"
        editor.focusChanged(to: nil)
        await settle(editor)

        XCTAssertEqual(settings.cursorSpend, SpendThresholds(warningCents: 9_000, criticalCents: 10_000))
    }

    func testTheStoreCommitsBothFieldsOfADraftAtOnce() async throws {
        let pair = try await settings.setThresholds(
            warning: .set(95),
            critical: .set(99),
            provider: provider,
            window: window
        )
        XCTAssertEqual(pair, ThresholdPair(warningPercent: 95, criticalPercent: 99))
        XCTAssertEqual(storedPair, pair)

        let spend = try await settings.setCursorSpend(warning: .set(9_000), critical: .set(10_000))
        XCTAssertEqual(spend, SpendThresholds(warningCents: 9_000, criticalCents: 10_000))
    }

    // MARK: saved once typing stops

    func testTheRowIsSavedOnceTypingStopsEvenWithFocusStillInIt() async {
        let editor = percentEditor()

        editor.focusChanged(to: .warning)
        editor.warningText = "60"
        editor.focusChanged(to: .critical)  // focus stays in the row
        await waitUntil { self.clock.sleeping == 1 }
        XCTAssertEqual(clock.durations, [.milliseconds(700)])
        XCTAssertEqual(disk.saves.count, 0)

        clock.fire()
        await waitUntil { !editor.hasPendingEdit }
        XCTAssertEqual(storedPair, ThresholdPair(warningPercent: 60, criticalPercent: 90))
        XCTAssertEqual(editor.warningText, "60")
    }

    func testTypingInCriticalRestartsTheDebounceAndSavesBothAsOneDraft() async {
        let editor = percentEditor()

        editor.focusChanged(to: .warning)
        editor.warningText = "95"
        await waitUntil { self.clock.sleeping == 1 }
        editor.focusChanged(to: .critical)
        editor.criticalText = "99"
        await waitUntil { self.clock.durations.count == 2 }

        // The first sleep ends 700 ms after the warning keystroke: typing in
        // critical cancelled it, so nothing is saved yet.
        clock.fireOldest()
        await drain()
        XCTAssertEqual(disk.saves.count, 0)

        clock.fire()
        await waitUntil { !editor.hasPendingEdit }
        await drain()
        XCTAssertEqual(disk.saves.count, 1)
        XCTAssertEqual(storedPair, ThresholdPair(warningPercent: 95, criticalPercent: 99))
    }

    func testTheDebounceNeverSavesAValueTheStoreWouldChange() async {
        let editor = percentEditor()

        editor.focusChanged(to: .warning)
        editor.warningText = "95"  // at or above critical 90: would become 89
        XCTAssertEqual(editor.flagged, [.warning: .adjusted(to: "89")])
        await waitUntil { self.clock.sleeping == 1 }
        clock.fire()
        await drain()

        XCTAssertEqual(disk.saves.count, 0)
        XCTAssertEqual(editor.warningText, "95", "not rewritten under the caret")

        // Leaving the row commits it, canonicalised, and shows the result.
        editor.focusChanged(to: nil)
        await settle(editor)
        XCTAssertEqual(storedPair, ThresholdPair(warningPercent: 89, criticalPercent: 90))
        XCTAssertEqual(editor.warningText, "89")
        XCTAssertEqual(editor.flagged, [:])
    }

    func testInvalidTextIsFlaggedAndNeverSavedByTheDebounce() async {
        let editor = percentEditor()

        editor.warningText = "7o"
        XCTAssertEqual(editor.flagged, [.warning: .invalid])
        await waitUntil { self.clock.sleeping == 1 }
        clock.fire()
        await drain()

        XCTAssertEqual(disk.saves.count, 0)
        XCTAssertEqual(editor.warningText, "7o", "shown as typed, flagged invalid")
        XCTAssertTrue(editor.hasPendingEdit)

        // VoiceOver hears why — only while the field is flagged.
        XCTAssertEqual(
            ThresholdFieldFlag.accessibilityNote(editor.flagged[.warning], locale: L10n.en),
            "Invalid value: not saved"
        )
        XCTAssertNil(ThresholdFieldFlag.accessibilityNote(editor.flagged[.critical], locale: L10n.en))

        editor.warningText = "70"
        XCTAssertEqual(editor.flagged, [:])
        XCTAssertNil(ThresholdFieldFlag.accessibilityNote(editor.flagged[.warning], locale: L10n.en))
    }

    func testACursorWarningAtOrAboveCriticalIsFlagged() async throws {
        try await settings.setCursorSpend(SpendThresholds(warningCents: 5_000, criticalCents: 8_000))
        let editor = spendEditor()

        editor.warningText = "90"
        XCTAssertEqual(editor.flagged, [.warning: .adjusted(to: "")], "90 ≥ 80 would turn the warning off")
        editor.criticalText = "100"
        XCTAssertEqual(editor.flagged, [:])
    }

    /// A mid-typing pause: critical "9" (the first digit of 99) over 75/90 would save 8/9 —
    /// the untouched warning pulled down — and finishing "99" left 8/99.
    func testAPauseMidNumberNeverCanonicalisesTheUntouchedSibling() async {
        let editor = percentEditor()

        editor.focusChanged(to: .critical)
        editor.criticalText = "9"
        XCTAssertEqual(editor.flagged, [.warning: .adjusted(to: "8")])
        await waitUntil { self.clock.sleeping == 1 }
        clock.fire()
        await drain()

        XCTAssertEqual(disk.saves.count, 0)
        XCTAssertEqual(storedPair, .default)
        XCTAssertEqual(editor.warningText, "75")
        XCTAssertEqual(editor.criticalText, "9")

        editor.criticalText = "99"
        XCTAssertEqual(editor.flagged, [:])
        editor.focusChanged(to: nil)
        await settle(editor)
        XCTAssertEqual(storedPair, ThresholdPair(warningPercent: 75, criticalPercent: 99))
        XCTAssertEqual(editor.warningText, "75")
    }

    func testAPauseAfterEachDigitStillEndsAtTheTypedPair() async {
        let editor = percentEditor()

        editor.focusChanged(to: .critical)
        editor.criticalText = "9"
        await waitUntil { self.clock.sleeping == 1 }
        clock.fire()
        await drain()
        editor.criticalText = "99"
        await waitUntil { self.clock.sleeping == 1 }
        clock.fire()
        await waitUntil { !editor.hasPendingEdit }

        XCTAssertEqual(disk.saves.count, 1)
        XCTAssertEqual(storedPair, ThresholdPair(warningPercent: 75, criticalPercent: 99))
    }

    func testACursorAmountIsNotSavedUnderTheCaretUntilItIsInDisplayForm() async {
        let editor = spendEditor()

        editor.focusChanged(to: .warning)
        editor.warningText = "9"
        XCTAssertEqual(editor.flagged, [:], "a valid value, only not yet in display form")
        await waitUntil { self.clock.sleeping == 1 }
        clock.fire()
        await drain()
        XCTAssertEqual(disk.saves.count, 0)
        XCTAssertEqual(editor.warningText, "9", "not reformatted to 9.00 under the caret")

        editor.warningText = "9.00"
        await waitUntil { self.clock.sleeping == 1 }
        clock.fire()
        await waitUntil { !editor.hasPendingEdit }
        XCTAssertEqual(settings.cursorSpend, SpendThresholds(warningCents: 900, criticalCents: nil))
        XCTAssertEqual(editor.warningText, "9.00")
    }

    func testAPercentWithALeadingZeroWaitsForTheRowToBeLeft() async {
        let editor = percentEditor()

        editor.warningText = "060"
        await waitUntil { self.clock.sleeping == 1 }
        clock.fire()
        await drain()
        XCTAssertEqual(disk.saves.count, 0)
        XCTAssertEqual(editor.warningText, "060")

        editor.focusChanged(to: nil)
        await settle(editor)
        XCTAssertEqual(storedPair, ThresholdPair(warningPercent: 60, criticalPercent: 90))
        XCTAssertEqual(editor.warningText, "60")
    }

    // MARK: shown values are committed values

    func testAFailedSaveShowsTheStoredValueAgain() async {
        let editor = percentEditor()
        disk.failNext = true

        editor.focusChanged(to: .warning)
        editor.warningText = "60"
        editor.focusChanged(to: nil)
        await settle(editor)

        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(storedPair, .default)
        XCTAssertEqual(editor.warningText, "75", "the field shows what is stored, not the failed edit")
        XCTAssertEqual(editor.criticalText, "90")
        XCTAssertFalse(editor.hasPendingEdit)
    }

    func testASiblingCanonicalisedWhileItHasFocusIsShown() async {
        let editor = percentEditor()
        disk.holds = true

        editor.focusChanged(to: .critical)
        editor.criticalText = "60"
        editor.focusChanged(to: nil)
        // The user clicks into Warning before the save lands.
        editor.focusChanged(to: .warning)
        await waitUntil { self.disk.waiting == 1 }
        disk.releaseAll()
        await settle(editor)

        XCTAssertEqual(storedPair, ThresholdPair(warningPercent: 59, criticalPercent: 60))
        XCTAssertEqual(editor.warningText, "59", "the focused field shows the canonicalised value")
        XCTAssertEqual(editor.criticalText, "60")

        // Leaving Warning unchanged commits nothing and still shows 59.
        editor.focusChanged(to: nil)
        await settle(editor)
        XCTAssertEqual(disk.saves.count, 1)
        XCTAssertEqual(editor.warningText, "59")
    }

    func testACanonicalisedValueIsShownEvenWhenTheStoreDoesNotChange() async throws {
        try await settings.setThresholds(ThresholdPair(warningPercent: 59, criticalPercent: 60), provider: provider, window: window)
        let editor = percentEditor()

        // 75 against critical 60 canonicalises back to the stored 59/60.
        editor.warningText = "75"
        editor.focusChanged(to: nil)
        await settle(editor)

        XCTAssertEqual(storedPair, ThresholdPair(warningPercent: 59, criticalPercent: 60))
        XCTAssertEqual(editor.warningText, "59")
    }

    func testAFieldTypedWhileASaveRunsKeepsItsText() async {
        let editor = percentEditor()
        disk.holds = true

        editor.criticalText = "60"
        editor.focusChanged(to: nil)
        await waitUntil { self.disk.waiting == 1 }
        editor.focusChanged(to: .warning)
        editor.warningText = "50"
        disk.releaseAll()
        await settle(editor)

        XCTAssertEqual(editor.warningText, "50", "a newer edit is not overwritten by the landed save")
        XCTAssertEqual(editor.criticalText, "60")
        XCTAssertTrue(editor.hasPendingEdit)

        disk.holds = false
        editor.focusChanged(to: nil)
        await settle(editor)
        XCTAssertEqual(storedPair, ThresholdPair(warningPercent: 50, criticalPercent: 60))
    }

    // MARK: validation is unchanged

    func testInvalidTextIsNotSavedAndShowsTheStoredValue() async {
        let editor = percentEditor()

        editor.warningText = "7o"
        editor.criticalText = ""
        XCTAssertTrue(editor.hasPendingEdit)
        editor.focusChanged(to: nil)
        await settle(editor)

        XCTAssertEqual(disk.saves.count, 0)
        XCTAssertEqual(editor.warningText, "75")
        XCTAssertEqual(editor.criticalText, "90")
        XCTAssertFalse(editor.hasPendingEdit)
    }

    func testABlankCursorFieldTurnsThatTierOff() async throws {
        try await settings.setCursorSpend(SpendThresholds(warningCents: 5_000, criticalCents: 8_000))
        let editor = spendEditor()

        editor.warningText = ""
        editor.focusChanged(to: nil)
        await settle(editor)

        XCTAssertEqual(settings.cursorSpend, SpendThresholds(warningCents: nil, criticalCents: 8_000))
        XCTAssertEqual(editor.warningText, "")
    }

    func testAnInvalidCursorFieldIsNotSaved() async throws {
        try await settings.setCursorSpend(SpendThresholds(warningCents: 5_000, criticalCents: 8_000))
        let savesBefore = disk.saves.count
        let editor = spendEditor()

        editor.warningText = "1,234.50"
        editor.focusChanged(to: nil)
        await settle(editor)

        XCTAssertEqual(disk.saves.count, savesBefore)
        XCTAssertEqual(editor.warningText, "50.00")
    }

    func testTheStoreChangingRedrawsFieldsTheUserHasNotChanged() async throws {
        let editor = percentEditor()
        editor.warningText = "80"

        try await settings.setThresholds(ThresholdPair(warningPercent: 40, criticalPercent: 70), provider: provider, window: window)
        editor.storeDidChange(storedPair)

        XCTAssertEqual(editor.warningText, "80", "the user's edit is kept")
        XCTAssertEqual(editor.criticalText, "70")
    }

    // MARK: helpers

    private func settle(_ editor: ThresholdDraftEditor<ThresholdPair, Int>) async {
        await editor.flushPendingEditWithoutSubmitting()
    }

    private func settle(_ editor: ThresholdDraftEditor<SpendThresholds, Int?>) async {
        await editor.flushPendingEditWithoutSubmitting()
    }

    private func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(2)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out waiting for condition", file: file, line: line)
    }
}

private extension ThresholdDraftEditor {
    /// Waits for every save already started, without committing the draft.
    func flushPendingEditWithoutSubmitting() async {
        for _ in 0..<200 {
            guard isSaving else { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

private struct DiskError: Error {}

/// The settings file's save: can fail once, or hold until released.
@MainActor
private final class DiskGate {
    var failNext = false
    var holds = false
    private(set) var saves: [AppSettingsData] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var waiting: Int { waiters.count }

    func save(_ data: AppSettingsData, to store: JSONFileStore<AppSettingsData>) async throws {
        saves.append(data)
        if holds {
            await withCheckedContinuation { waiters.append($0) }
        }
        if failNext {
            failNext = false
            throw DiskError()
        }
        try await store.save(data)
    }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

/// Sleeps that end only when the test fires them.
@MainActor
private final class DebounceClock {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var sleeping = 0
    private(set) var durations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        durations.append(duration)
        sleeping += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func fireOldest() {
        guard !waiters.isEmpty else { return }
        let first = waiters.removeFirst()
        sleeping -= 1
        first.resume()
    }

    func fire() {
        let pending = waiters
        waiters.removeAll()
        sleeping = 0
        for waiter in pending {
            waiter.resume()
        }
    }
}
