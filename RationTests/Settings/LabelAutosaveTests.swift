import XCTest
@testable import Ration

@MainActor
final class LabelAutosaveTests: XCTestCase {
    private var clock: ManualDebounceClock!
    private var renamer: FakeRenamer!
    private var errors: [Error] = []
    private var clearedErrors = 0

    override func setUp() async throws {
        clock = ManualDebounceClock()
        renamer = FakeRenamer()
        errors = []
        clearedErrors = 0
    }

    private func makeAutosave(stored: String = "Work", busyRetryLimit: Int = 120) -> LabelAutosave {
        let clock = clock!
        let renamer = renamer!
        return LabelAutosave(
            stored: stored,
            sleep: { try await clock.sleep($0) },
            busyRetryLimit: busyRetryLimit,
            save: { try await renamer.save($0) },
            onError: { [weak self] error in
                if let error { self?.errors.append(error) } else { self?.clearedErrors += 1 }
            }
        )
    }

    // MARK: typing

    func testTypingSavesTheTrimmedLabelOnceTypingPauses() async {
        let autosave = makeAutosave()
        autosave.focusChanged(true)

        autosave.text = "  Home "
        XCTAssertFalse(autosave.isSettled)
        await waitUntil { self.clock.sleeping == 1 }
        XCTAssertEqual(renamer.calls, [], "nothing is saved before the debounce elapses")

        clock.fire()
        await waitUntil { autosave.isSettled }
        XCTAssertEqual(renamer.calls, ["Home"])
    }

    func testRapidEditsSaveOnlyTheNewestValue() async {
        let autosave = makeAutosave()

        autosave.text = "H"
        autosave.text = "Ho"
        autosave.text = "Home"
        await waitUntil { self.clock.sleeping == 1 }
        await drain()
        XCTAssertEqual(clock.durations, [LabelAutosave.debounce], "superseded waits never start")
        clock.fire()
        await waitUntil { autosave.isSettled }
        await drain()

        XCTAssertEqual(renamer.calls, ["Home"])
    }

    func testEachKeystrokeRestartsTheDebounce() async {
        let autosave = makeAutosave()

        autosave.text = "H"
        await waitUntil { self.clock.sleeping == 1 }
        autosave.text = "Ho"
        await waitUntil { self.clock.sleeping == 2 }
        clock.fireOldest()
        await drain()
        XCTAssertEqual(renamer.calls, [], "the first keystroke's wait was superseded")

        clock.fire()
        await waitUntil { autosave.isSettled }
        XCTAssertEqual(renamer.calls, ["Ho"])
    }

    func testEditMatchingTheStoredLabelSavesNothing() async {
        let autosave = makeAutosave(stored: "Work")

        autosave.text = "Work "
        XCTAssertTrue(autosave.isSettled)
        autosave.flush()
        await drain()

        XCTAssertEqual(renamer.calls, [])
    }

    func testBlankLabelIsNeverSaved() async {
        let autosave = makeAutosave()

        autosave.text = "   "
        XCTAssertTrue(autosave.isSettled)
        autosave.text = ""
        autosave.flush()
        await drain()

        XCTAssertEqual(renamer.calls, [])
    }

    func testClearingTheFieldCancelsAPendingSave() async {
        let autosave = makeAutosave()

        autosave.text = "Home"
        await waitUntil { self.clock.sleeping == 1 }
        autosave.text = ""
        XCTAssertTrue(autosave.isSettled)
        clock.fire()
        await drain()

        XCTAssertEqual(renamer.calls, [])
    }

    // MARK: flush (blur / Return / pane closing)

    func testBlurSavesWithoutWaitingForTheDebounce() async {
        let autosave = makeAutosave()
        autosave.focusChanged(true)

        autosave.text = "Home"
        autosave.focusChanged(false)
        await waitUntil { autosave.isSettled }

        XCTAssertEqual(renamer.calls, ["Home"])
        clock.fire()
        await drain()
        XCTAssertEqual(renamer.calls, ["Home"], "the cancelled debounce must not save again")
    }

    func testFlushDuringADebounceSavesOnce() async {
        let autosave = makeAutosave()

        autosave.text = "Home"
        await waitUntil { self.clock.sleeping == 1 }
        autosave.flush()
        await waitUntil { autosave.isSettled }
        clock.fire()
        await drain()

        XCTAssertEqual(clock.durations, [LabelAutosave.debounce])
        XCTAssertEqual(renamer.calls, ["Home"])
    }

    // MARK: a save already running

    func testSavesNeverOverlapAndTheNewestEditWins() async {
        renamer.holds = true
        let autosave = makeAutosave()

        autosave.text = "A"
        autosave.flush()
        await waitUntil { self.renamer.running == 1 }
        autosave.text = "AB"
        autosave.text = "ABC"
        autosave.flush()
        await drain()
        XCTAssertEqual(renamer.calls, ["A"], "a second save must wait for the running one")

        renamer.releaseAll()
        await waitUntil { self.renamer.calls.count == 2 }
        XCTAssertEqual(renamer.calls, ["A", "ABC"])
        XCTAssertFalse(autosave.isSettled)

        renamer.releaseAll()
        await waitUntil { autosave.isSettled }
        XCTAssertEqual(renamer.maxRunning, 1)
    }

    /// An edit queued behind a running save is still debounced: finishing the
    /// running save must not start it early.
    func testAnEditBehindARunningSaveStillWaitsForItsDebounce() async {
        renamer.holds = true
        let autosave = makeAutosave()

        autosave.text = "A"
        autosave.flush()
        await waitUntil { self.renamer.running == 1 }
        autosave.text = "AB"
        await waitUntil { self.clock.sleeping == 1 }
        renamer.releaseAll()
        await waitUntil { self.renamer.running == 0 }
        await drain()
        XCTAssertEqual(renamer.calls, ["A"])

        clock.fire()
        await waitUntil { self.renamer.calls.count == 2 }
        renamer.releaseAll()
        await waitUntil { autosave.isSettled }
        XCTAssertEqual(renamer.calls, ["A", "AB"])
    }

    /// The published label still reads the old value while a save runs, so an
    /// edit back to it must be compared with what the store is ABOUT to hold.
    func testReturningToTheOldLabelWhileASaveRunsIsStillSaved() async {
        renamer.holds = true
        let autosave = makeAutosave(stored: "Work")

        autosave.text = "Work2"
        autosave.flush()
        await waitUntil { self.renamer.running == 1 }
        autosave.text = "Work"
        autosave.flush()
        XCTAssertFalse(autosave.isSettled)

        renamer.releaseAll()
        await waitUntil { self.renamer.calls.count == 2 }
        renamer.releaseAll()
        await waitUntil { autosave.isSettled }

        XCTAssertEqual(renamer.calls, ["Work2", "Work"])
    }

    func testEditMatchingTheRunningSaveQueuesNothing() async {
        renamer.holds = true
        let autosave = makeAutosave()

        autosave.text = "Home"
        autosave.flush()
        await waitUntil { self.renamer.running == 1 }
        autosave.text = "Home "
        autosave.flush()
        renamer.releaseAll()
        await waitUntil { autosave.isSettled }
        await drain()

        XCTAssertEqual(renamer.calls, ["Home"])
    }

    // MARK: failures

    func testFailedSaveIsReportedKeepsTheTextAndIsRetriedOnFlush() async {
        renamer.failures = [SaveFailed()]
        let autosave = makeAutosave(stored: "Work")
        autosave.focusChanged(true)

        autosave.text = "Home"
        autosave.focusChanged(false)
        await waitUntil { self.errors.count == 1 }
        await drain()
        XCTAssertFalse(autosave.isSettled)
        XCTAssertEqual(autosave.text, "Home", "a failed save must not revert the user's text")

        XCTAssertEqual(clock.sleeping, 0, "only a busy account is retried on its own")

        autosave.flush()
        await waitUntil { autosave.isSettled }
        XCTAssertEqual(renamer.calls, ["Home", "Home"])
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(clearedErrors, 1, "the success clears the earlier report")

        autosave.text = "Office"
        autosave.flush()
        await waitUntil { autosave.isSettled }
        XCTAssertEqual(renamer.calls, ["Home", "Home", "Office"])
        XCTAssertEqual(clearedErrors, 1, "only the first success after a report clears it")
    }

    func testSuccessWithoutAnEarlierFailureClearsNoReport() async {
        let autosave = makeAutosave()

        autosave.text = "Home"
        autosave.flush()
        await waitUntil { autosave.isSettled }

        XCTAssertEqual(clearedErrors, 0, "must not wipe another action's error banner")
    }

    func testFailureSupersededByANewerEditIsNotRetried() async {
        renamer.holds = true
        renamer.failures = [SaveFailed()]
        let autosave = makeAutosave()

        autosave.text = "A"
        autosave.flush()
        await waitUntil { self.renamer.running == 1 }
        autosave.text = "AB"
        autosave.flush()
        renamer.releaseAll()
        await waitUntil { self.renamer.calls.count == 2 }
        renamer.releaseAll()
        await waitUntil { autosave.isSettled }

        XCTAssertEqual(renamer.calls, ["A", "AB"])
        XCTAssertEqual(errors.count, 1)
    }

    func testEditingBackToTheStoredLabelClearsAFailure() async {
        renamer.failures = [SaveFailed()]
        let autosave = makeAutosave(stored: "Work")

        autosave.text = "Home"
        autosave.flush()
        await waitUntil { self.errors.count == 1 }
        await drain()
        XCTAssertFalse(autosave.isSettled)

        autosave.text = "Work"
        XCTAssertTrue(autosave.isSettled)
        await drain()
        XCTAssertEqual(renamer.calls, ["Home"])
    }

    // MARK: busy account

    func testBusyAccountIsRetriedWithoutReportingAnError() async {
        renamer.failures = [AccountStoreError.operationInProgress]
        let autosave = makeAutosave(stored: "Work")

        autosave.text = "Home"
        autosave.flush()
        await waitUntil { self.clock.sleeping == 1 }
        XCTAssertEqual(clock.durations, [LabelAutosave.busyRetryInterval])
        XCTAssertEqual(errors.count, 0)
        XCTAssertFalse(autosave.isSettled)

        // Nothing but the retry wait triggers the second attempt, so it also
        // lands after the pane that started it is gone.
        clock.fire()
        await waitUntil { autosave.isSettled }
        XCTAssertEqual(renamer.calls, ["Home", "Home"])
        XCTAssertEqual(errors.count, 0)
        XCTAssertEqual(clearedErrors, 0)
    }

    /// The pane that owned the model can be gone by the time the account is
    /// free; the retry wait itself must keep the model alive, then let go.
    func testBusyRetryKeepsTheModelAliveAfterItsOwnerIsGone() async {
        renamer.failures = [AccountStoreError.operationInProgress]
        weak var weakAutosave: LabelAutosave?
        do {
            let autosave = makeAutosave()
            weakAutosave = autosave
            autosave.text = "Home"
            autosave.flush()
        }
        await waitUntil { self.clock.sleeping == 1 }
        XCTAssertNotNil(weakAutosave)

        clock.fire()
        await waitUntil { self.renamer.calls.count == 2 }
        await waitUntil { weakAutosave == nil }
        XCTAssertEqual(renamer.calls, ["Home", "Home"])
    }

    func testNewerEditReplacesTheValueWaitingOnABusyAccount() async {
        renamer.holds = true
        renamer.failures = [AccountStoreError.operationInProgress]
        let autosave = makeAutosave()

        autosave.text = "A"
        autosave.flush()
        await waitUntil { self.renamer.running == 1 }
        autosave.text = "AB"
        await waitUntil { self.clock.sleeping == 1 }
        renamer.releaseAll()
        await waitUntil { self.renamer.running == 0 }
        await drain()
        XCTAssertEqual(clock.durations, [LabelAutosave.debounce], "the pending edit's debounce stands in for the retry wait")

        clock.fire()
        await waitUntil { self.renamer.calls.count == 2 }
        renamer.releaseAll()
        await waitUntil { autosave.isSettled }
        XCTAssertEqual(renamer.calls, ["A", "AB"])
        XCTAssertEqual(errors.count, 0)
    }

    func testBusyRetriesGiveUpAfterTheLimitAndReport() async {
        renamer.failures = Array(repeating: AccountStoreError.operationInProgress, count: 3)
        let autosave = makeAutosave(busyRetryLimit: 2)

        autosave.text = "Home"
        autosave.flush()
        for attempt in 1...2 {
            await waitUntil { self.clock.sleeping == 1 && self.renamer.calls.count == attempt }
            clock.fire()
        }
        await waitUntil { self.errors.count == 1 }
        await drain()

        XCTAssertEqual(renamer.calls, ["Home", "Home", "Home"])
        XCTAssertEqual(clock.sleeping, 0)
        XCTAssertFalse(autosave.isSettled)
        XCTAssertEqual(autosave.text, "Home")
    }

    func testBusyRetryBudgetResetsAfterASuccess() async {
        let busy = AccountStoreError.operationInProgress
        renamer.failures = [busy, nil, busy, nil]
        let autosave = makeAutosave(busyRetryLimit: 1)

        autosave.text = "A"
        autosave.flush()
        await waitUntil { self.clock.sleeping == 1 }
        clock.fire()
        await waitUntil { autosave.isSettled }

        autosave.text = "B"
        autosave.flush()
        await waitUntil { self.clock.sleeping == 1 }
        clock.fire()
        await waitUntil { autosave.isSettled }

        XCTAssertEqual(renamer.calls, ["A", "A", "B", "B"])
        XCTAssertEqual(errors.count, 0)
    }

    func testEditingBackToTheStoredLabelCancelsABusyRetry() async {
        renamer.failures = [AccountStoreError.operationInProgress]
        let autosave = makeAutosave(stored: "Work")

        autosave.text = "Home"
        autosave.flush()
        await waitUntil { self.clock.sleeping == 1 }
        autosave.text = "Work"
        XCTAssertTrue(autosave.isSettled)
        clock.fire()
        await drain()

        XCTAssertEqual(renamer.calls, ["Home"])
    }

    func testFlushDuringABusyWaitTriesAtOnce() async {
        renamer.failures = [AccountStoreError.operationInProgress]
        let autosave = makeAutosave()

        autosave.text = "Home"
        autosave.flush()
        await waitUntil { self.clock.sleeping == 1 }
        autosave.flush()
        await waitUntil { autosave.isSettled }

        XCTAssertEqual(renamer.calls, ["Home", "Home"])
    }

    // MARK: following the store

    /// A landed save is the new baseline even before the store's publish
    /// reaches the view, so going back to the old label is a real edit.
    func testGoingBackToThePreviousLabelAfterASaveIsSaved() async {
        let autosave = makeAutosave(stored: "Work")

        autosave.text = "Home"
        autosave.flush()
        await waitUntil { autosave.isSettled }
        autosave.text = "Work"
        autosave.flush()
        await waitUntil { self.renamer.calls.count == 2 }
        autosave.flush()
        await drain()

        XCTAssertEqual(renamer.calls, ["Home", "Work"])
    }

    /// A re-sign-in can store a new label while the field is focused but
    /// untouched. The field must show it, so the blur doesn't write the stale
    /// text back over it.
    func testLabelChangedElsewhereReplacesAnUntouchedFocusedField() async {
        let autosave = makeAutosave(stored: "Work")
        autosave.focusChanged(true)

        autosave.storeDidChange("Personal")
        XCTAssertEqual(autosave.text, "Personal")

        autosave.focusChanged(false)
        await drain()
        XCTAssertEqual(renamer.calls, [])
        XCTAssertEqual(autosave.text, "Personal")
    }

    func testLabelChangedElsewhereNeverOverwritesUnsavedTyping() async {
        let autosave = makeAutosave(stored: "Work")
        autosave.focusChanged(true)

        autosave.text = "Home"
        autosave.storeDidChange("Personal")
        XCTAssertEqual(autosave.text, "Home")

        autosave.focusChanged(false)
        await waitUntil { autosave.isSettled }
        XCTAssertEqual(renamer.calls, ["Home"])
        XCTAssertEqual(autosave.text, "Home")
    }

    func testLabelChangedElsewhereWhileUnfocusedIsShown() async {
        let autosave = makeAutosave(stored: "Work")

        autosave.storeDidChange("Personal")
        XCTAssertEqual(autosave.text, "Personal")
        autosave.flush()
        await drain()
        XCTAssertEqual(renamer.calls, [])
    }

    /// The store trims, and its echo must not strip a space from under the
    /// caret while the user is still typing.
    func testOwnSaveEchoLeavesAFocusedFieldAlone() async {
        let autosave = makeAutosave(stored: "Work")
        autosave.focusChanged(true)

        autosave.text = "My "
        await waitUntil { self.clock.sleeping == 1 }
        clock.fire()
        await waitUntil { autosave.isSettled }
        autosave.storeDidChange("My")
        XCTAssertEqual(autosave.text, "My ")

        autosave.text = "My W"
        XCTAssertFalse(autosave.isSettled)
        XCTAssertEqual(autosave.text, "My W")
    }

    /// The echo can reach the view before the save's own continuation runs.
    func testOwnSaveEchoArrivingMidSaveLeavesAFocusedFieldAlone() async {
        renamer.holds = true
        let autosave = makeAutosave(stored: "Work")
        autosave.focusChanged(true)

        autosave.text = "My "
        await waitUntil { self.clock.sleeping == 1 }
        clock.fire()
        await waitUntil { self.renamer.running == 1 }
        autosave.storeDidChange("My")
        XCTAssertEqual(autosave.text, "My ")

        renamer.releaseAll()
        await waitUntil { autosave.isSettled }
        XCTAssertEqual(autosave.text, "My ")
        XCTAssertEqual(renamer.calls, ["My"])
    }

    func testBlurShowsTheTrimmedStoredLabel() async {
        let autosave = makeAutosave(stored: "Work")
        autosave.focusChanged(true)

        autosave.text = " Home  "
        autosave.focusChanged(false)
        await waitUntil { autosave.isSettled }

        XCTAssertEqual(autosave.text, "Home")
    }

    func testBlurRestoresAClearedField() async {
        let autosave = makeAutosave(stored: "Work")
        autosave.focusChanged(true)

        autosave.text = ""
        autosave.focusChanged(false)

        XCTAssertEqual(autosave.text, "Work")
        await drain()
        XCTAssertEqual(renamer.calls, [])
    }

    // MARK: helpers

    /// Lets already-scheduled main-actor work run; for asserting that
    /// something did NOT happen.
    private func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func waitUntil(
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(condition(), "timed out waiting for condition", file: file, line: line)
    }
}

/// Sleeps that end only when the test fires them. Like `Task.sleep`, a task
/// cancelled before it sleeps throws at once; one cancelled while asleep
/// still wakes on `fire()`, and the autosave must ignore it.
@MainActor
private final class ManualDebounceClock {
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
        sleeping -= 1
        waiters.removeFirst().resume()
    }

    func fire() {
        let pending = waiters
        waiters.removeAll()
        sleeping = 0
        pending.forEach { $0.resume() }
    }
}

private struct SaveFailed: Error {}

/// Stands in for `AppModel.renameAccount`: records calls, tracks overlap, and
/// optionally holds each save until released or fails it.
@MainActor
private final class FakeRenamer {
    private(set) var calls: [String] = []
    private(set) var running = 0
    private(set) var maxRunning = 0
    var holds = false
    /// Consumed in call order; `nil` (or running out) means success.
    var failures: [Error?] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func save(_ label: String) async throws {
        calls.append(label)
        running += 1
        maxRunning = max(maxRunning, running)
        defer { running -= 1 }
        if holds {
            await withCheckedContinuation { waiters.append($0) }
        }
        if !failures.isEmpty, let error = failures.removeFirst() {
            throw error
        }
    }

    func releaseAll() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
