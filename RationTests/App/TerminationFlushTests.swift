import AppKit
import XCTest
@testable import Ration

/// Quitting inside the 400 ms debounce of a Settings edit must
/// save that edit. These drive the delegate's real `applicationShouldTerminate`
/// against a real `AppModel` over temporary files; only the reply to AppKit
/// is captured instead of sent to the test host's `NSApp`.
@MainActor
final class TerminationFlushTests: XCTestCase {
    private var fixture: TerminationTestModel?

    override func tearDown() async throws {
        fixture?.removeFiles()
        fixture = nil
    }

    private struct Quit {
        let delegate: RationApplicationDelegate
        let replies: ReplyRecorder
    }

    private func makeQuit(model: AppModel) -> Quit {
        let delegate = RationApplicationDelegate()
        delegate.relauncher = AppRelauncher(
            launcher: NoLaunches(),
            terminator: NoTerminate(),
            clock: InstantClock(),
            handoff: RelaunchHandoff(defaults: UserDefaults(suiteName: "TerminationFlushTests")!),
            bundleURL: URL(fileURLWithPath: "/Applications/Ration.app"),
            processID: 4242,
            log: { _ in }
        )
        delegate.model = model
        let replies = ReplyRecorder()
        delegate.replyToTermination = { _, canTerminate in
            replies.values.append(canTerminate)
        }
        return Quit(delegate: delegate, replies: replies)
    }

    func testAPendingLabelEditIsSavedWhenQuittingWithinTheDebounce() async throws {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        let autosave = fixture.labelAutosave()
        let quit = makeQuit(model: fixture.model)

        autosave.text = "Personal"  // ⌘Q lands well inside the 400 ms debounce
        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateLater)
        await quit.delegate.terminationPreparation?.value
        XCTAssertEqual(quit.replies.values, [true])
        let label = try await fixture.labelOnDisk()
        XCTAssertEqual(label, "Personal")
    }

    func testAPendingQuietHoursEditIsSavedWhenQuittingWithinTheDebounce() async throws {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        let autosave = fixture.quietHoursAutosave()
        let quit = makeQuit(model: fixture.model)

        autosave.select([22, 23, 0])
        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateLater)
        await quit.delegate.terminationPreparation?.value
        XCTAssertEqual(quit.replies.values, [true])
        let cells = try await fixture.quietHoursOnDisk()
        XCTAssertEqual(cells, [0, 22, 23])
    }

    func testAFocusedHolidayLabelIsSavedWhenQuitting() async throws {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        let holiday = HolidayRange(
            start: LocalDate(year: 2026, month: 12, day: 24),
            end: LocalDate(year: 2026, month: 12, day: 26),
            label: ""
        )
        try await fixture.model.addHoliday(holiday)
        let editor = fixture.holidayLabelEditor(holiday)
        let quit = makeQuit(model: fixture.model)

        editor.focusChanged(true)
        editor.text = "Winter"  // still focused: no blur has committed it
        XCTAssertTrue(fixture.model.requiresTerminationPreparation)
        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateLater)
        await quit.delegate.terminationPreparation?.value
        XCTAssertEqual(quit.replies.values, [true])
        let settings = try await fixture.settingsOnDisk()
        XCTAssertEqual(settings.holidays.map(\.label), ["Winter"])
    }

    /// The pane closes, its label save then fails. The edit must not
    /// go with the pane: reopening shows it and the error, and a quit saves it.
    func testAHolidayLabelWhoseSaveFailedAfterThePaneClosedSurvivesUntilQuit() async throws {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        let holiday = HolidayRange(
            start: LocalDate(year: 2026, month: 12, day: 24),
            end: LocalDate(year: 2026, month: 12, day: 26),
            label: "Old"
        )
        try await fixture.model.addHoliday(holiday)
        let disk = FlakyLabelSave(fixture.model)
        let errors = ErrorLog()
        var pane: HolidayLabelEditor? = fixture.holidayLabelEditor(
            holiday,
            save: disk.save,
            onError: { errors.values.append($0) }
        )
        weak var closed = pane

        pane?.text = "Winter"
        pane?.commit()  // the pane's `.onDisappear`
        pane = nil
        await waitUntil { errors.values.count == 1 }
        await waitUntil { closed?.isSaving == false }
        XCTAssertNotNil(closed, "an unsaved edit outlives its pane")
        XCTAssertTrue(fixture.model.requiresTerminationPreparation)

        let reopenedErrors = ErrorLog()
        let reopened = fixture.holidayLabelEditor(
            holiday,
            save: disk.save,
            onError: { reopenedErrors.values.append($0) }
        )
        XCTAssertTrue(reopened === closed, "the reopened pane continues with the live editor")
        XCTAssertEqual(reopened.text, "Winter")
        reopened.paneAppeared()
        XCTAssertEqual(reopenedErrors.values.count, 1, "the failed save is reported again")

        let quit = makeQuit(model: fixture.model)
        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)
        await quit.delegate.terminationPreparation?.value
        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(quit.replies.values, [true])
        let settings = try await fixture.settingsOnDisk()
        XCTAssertEqual(settings.holidays.map(\.label), ["Winter"])
    }

    /// A failed label edit is kept for quit — but not once its
    /// holiday has been removed.
    func testRemovingAHolidayDropsItsFailedLabelEditSoQuitDoesNotRetryIt() async throws {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        let holiday = HolidayRange(
            start: LocalDate(year: 2026, month: 12, day: 24),
            end: LocalDate(year: 2026, month: 12, day: 26),
            label: "Old"
        )
        try await fixture.model.addHoliday(holiday)
        let disk = FlakyLabelSave(fixture.model)
        let errors = ErrorLog()
        var pane: HolidayLabelEditor? = fixture.holidayLabelEditor(
            holiday,
            save: disk.save,
            onError: { errors.values.append($0) }
        )
        weak var closed = pane
        pane?.text = "Winter"
        pane?.commit()
        pane = nil
        await waitUntil { errors.values.count == 1 }
        await waitUntil { closed?.isSaving == false }
        XCTAssertNotNil(closed)

        try await fixture.model.removeHoliday(id: holiday.id)

        XCTAssertNil(closed, "the removed holiday's edit is released")
        XCTAssertFalse(fixture.model.requiresTerminationPreparation)
        let quit = makeQuit(model: fixture.model)
        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)
        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(disk.calls, 1, "quit does not retry the stale edit")
    }

    func testASavedHolidayLabelEditorIsReleasedWithItsPane() async throws {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        let holiday = HolidayRange(
            start: LocalDate(year: 2026, month: 12, day: 24),
            end: LocalDate(year: 2026, month: 12, day: 26),
            label: "Old"
        )
        try await fixture.model.addHoliday(holiday)
        var pane: HolidayLabelEditor? = fixture.holidayLabelEditor(holiday)
        weak var closed = pane

        pane?.text = "Winter"
        await pane?.flushPendingEdit()
        pane = nil

        XCTAssertNil(closed, "nothing unsaved, nothing kept alive")
        XCTAssertFalse(fixture.model.requiresTerminationPreparation)
    }

    func testAFocusedThresholdFieldIsSavedThroughValidationWhenQuitting() async throws {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        let editor = fixture.thresholdEditor(provider: .claude, window: .fiveHour)
        let quit = makeQuit(model: fixture.model)

        editor.focusChanged(to: .critical)
        editor.criticalText = "60"  // canonicalises warning 75 → 59
        XCTAssertTrue(fixture.model.requiresTerminationPreparation)
        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateLater)
        await quit.delegate.terminationPreparation?.value
        XCTAssertEqual(quit.replies.values, [true])
        let settings = try await fixture.settingsOnDisk()
        XCTAssertEqual(
            settings.data.thresholds(provider: .claude, window: .fiveHour),
            ThresholdPair(warningPercent: 59, criticalPercent: 60)
        )
    }

    func testAnInvalidFocusedThresholdFieldSavesNothingWhenQuitting() async throws {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        let editor = fixture.thresholdEditor(provider: .claude, window: .fiveHour)
        let quit = makeQuit(model: fixture.model)

        editor.focusChanged(to: .warning)
        editor.warningText = "6o"
        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)
        await quit.delegate.terminationPreparation?.value

        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(quit.replies.values, [true])
        let settings = try await fixture.settingsOnDisk()
        XCTAssertTrue(settings.alertThresholds.isEmpty, "invalid text never reaches the file")
        XCTAssertEqual(editor.warningText, "75")
    }

    func testAFocusedCursorSpendFieldIsSavedWhenQuitting() async throws {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        let editor = fixture.cursorSpendEditor()
        let quit = makeQuit(model: fixture.model)

        editor.focusChanged(to: .critical)
        editor.criticalText = "12.50"
        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)
        await quit.delegate.terminationPreparation?.value

        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(quit.replies.values, [true])
        let settings = try await fixture.settingsOnDisk()
        XCTAssertEqual(settings.cursorSpend, SpendThresholds(warningCents: nil, criticalCents: 1_250))
    }

    func testAnInvalidFocusedCursorSpendFieldSavesNothingWhenQuitting() async throws {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        let editor = fixture.cursorSpendEditor()
        let quit = makeQuit(model: fixture.model)

        editor.focusChanged(to: .warning)
        editor.warningText = "12..5"
        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)
        await quit.delegate.terminationPreparation?.value

        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(quit.replies.values, [true])
        let settings = try await fixture.settingsOnDisk()
        XCTAssertEqual(settings.cursorSpend, .off)
        XCTAssertEqual(editor.warningText, "")
    }

    func testNoPendingEditQuitsAtOnce() async throws {
        let fixture = try await TerminationTestModel.make()
        self.fixture = fixture
        // Editors exist, but everything they hold is saved.
        let label = fixture.labelAutosave()
        let quietHours = fixture.quietHoursAutosave()
        let quit = makeQuit(model: fixture.model)

        XCTAssertFalse(fixture.model.requiresTerminationPreparation)
        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)

        XCTAssertEqual(reply, .terminateNow)
        XCTAssertNil(quit.delegate.terminationPreparation)
        XCTAssertTrue(quit.replies.values.isEmpty)
        withExtendedLifetime((label, quietHours)) {}
    }

    func testAStuckSaveLetsTheQuitProceedAfterTheTimeout() async throws {
        let fixture = try await TerminationTestModel.make(
            pendingEdits: PendingEditRegistry(timeout: .milliseconds(100))
        )
        self.fixture = fixture
        let gate = StuckSave()
        let autosave = LabelAutosave.editor(
            accountID: fixture.account.id,
            stored: "Work",
            in: fixture.model.pendingEdits,
            save: { _ in await gate.hang() },
            onError: { _ in }
        )
        let quit = makeQuit(model: fixture.model)
        autosave.text = "Personal"
        let started = Date()

        let reply = quit.delegate.applicationShouldTerminate(NSApplication.shared)
        await quit.delegate.terminationPreparation?.value

        XCTAssertEqual(reply, .terminateLater)
        XCTAssertEqual(quit.replies.values, [true], "a stuck save never blocks quitting")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
        XCTAssertTrue(gate.isHanging, "the save really was stuck")
        gate.release()
    }
}

private extension TerminationFlushTests {
    func waitUntil(
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

@MainActor
private final class ErrorLog {
    var values: [Error] = []
}

private struct LabelDiskError: Error {}

/// The model's holiday-label save, failing its first call.
@MainActor
private final class FlakyLabelSave {
    private let bound: SettingsEditors.HolidayLabelSave
    private var failed = false
    private(set) var calls = 0

    init(_ model: AppModel) {
        bound = SettingsEditors.holidayLabelSave(model)
    }

    var save: SettingsEditors.HolidayLabelSave {
        { [self] id, label in
            calls += 1
            if !failed {
                failed = true
                throw LabelDiskError()
            }
            try await bound(id, label)
        }
    }
}

@MainActor
private final class ReplyRecorder {
    var values: [Bool] = []
}

/// A save that never finishes until released.
@MainActor
private final class StuckSave {
    private(set) var isHanging = false
    private var waiter: CheckedContinuation<Void, Never>?

    func hang() async {
        isHanging = true
        await withCheckedContinuation { waiter = $0 }
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}

@MainActor
private final class NoLaunches: NewInstanceLaunching {
    func launchNewInstance(at url: URL, arguments: [String]) -> NewInstanceLaunchOutcome {
        XCTFail("an ordinary quit must not launch anything")
        return .launched
    }
}

@MainActor
private final class NoTerminate: AppTerminating {
    func terminate() {}
}

@MainActor
private final class InstantClock: RelaunchClock {
    func now() -> Date { Date(timeIntervalSince1970: 1_800_000_000) }
    func sleep(seconds: TimeInterval) async {}
}
