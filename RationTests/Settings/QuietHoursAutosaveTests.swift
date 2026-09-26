import XCTest
@testable import Ration

/// The quiet-hours grid's model: saves 400 ms after the last change, keeps a
/// failed edit dirty, and lets a quit save an edit still in its debounce.
@MainActor
final class QuietHoursAutosaveTests: XCTestCase {
    private var clock: QuietHoursClock!
    private var saves: [[Int]] = []
    private var failures: [Error?] = []
    private var errors: [Error] = []
    private var holds = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override func setUp() async throws {
        clock = QuietHoursClock()
        saves = []
        failures = []
        errors = []
        holds = false
        waiters = []
    }

    private func makeAutosave(
        stored: [Int] = [],
        pendingEdits: PendingEditRegistry? = nil
    ) -> QuietHoursAutosave {
        let clock = clock!
        return QuietHoursAutosave.editor(
            stored: stored,
            sleep: { try await clock.sleep($0) },
            in: pendingEdits,
            save: { [weak self] cells in
                guard let self else { return }
                try await self.save(cells)
            },
            onError: { [weak self] error in
                guard let self else { return }
                self.errors.append(error)
            }
        )
    }

    private func save(_ cells: [Int]) async throws {
        saves.append(cells.sorted())
        if holds {
            await withCheckedContinuation { waiters.append($0) }
        }
        if !failures.isEmpty, let error = failures.removeFirst() {
            throw error
        }
    }

    private func releaseSaves() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }

    func testAChangeIsSavedOnceTheDebounceElapses() async {
        let autosave = makeAutosave()

        autosave.select([3, 1])
        XCTAssertEqual(autosave.draft, [1, 3])
        XCTAssertTrue(autosave.hasPendingEdit)
        await waitUntil { self.clock.sleeping == 1 }
        XCTAssertEqual(clock.durations, [QuietHoursAutosave.debounce])
        XCTAssertEqual(saves, [])

        clock.fire()
        await waitUntil { !autosave.hasPendingEdit }
        XCTAssertEqual(saves, [[1, 3]])
    }

    func testTheDebounceIsFourHundredMilliseconds() {
        XCTAssertEqual(QuietHoursAutosave.debounce, .milliseconds(400))
    }

    func testRapidChangesSaveOnlyTheNewest() async {
        let autosave = makeAutosave()

        autosave.select([1])
        autosave.select([1, 2])
        await waitUntil { self.clock.sleeping >= 1 }
        clock.fire()
        await waitUntil { !autosave.hasPendingEdit }
        await drain()

        XCTAssertEqual(saves, [[1, 2]])
    }

    func testSelectingTheSameCellsIsNotAnEdit() {
        let autosave = makeAutosave(stored: [4])

        autosave.select([4])

        XCTAssertFalse(autosave.hasPendingEdit)
    }

    func testTheStoreIsAdoptedOnlyWhileClean() async {
        let autosave = makeAutosave(stored: [1])
        autosave.storeDidChange([2])
        XCTAssertEqual(autosave.draft, [2])

        autosave.select([5])
        autosave.storeDidChange([9])

        XCTAssertEqual(autosave.draft, [5], "a dirty draft is never clobbered")
    }

    func testAFailedSaveStaysDirtyAndIsReported() async {
        failures = [SaveError()]
        let autosave = makeAutosave()

        autosave.select([7])
        await waitUntil { self.clock.sleeping == 1 }
        clock.fire()
        await waitUntil { self.errors.count == 1 }

        XCTAssertTrue(autosave.hasPendingEdit)
    }

    func testFlushOnDisappearSavesWithoutTheDebounce() async {
        let autosave = makeAutosave()
        autosave.select([2])

        autosave.flush()
        await waitUntil { !autosave.hasPendingEdit }

        XCTAssertEqual(saves, [[2]])
    }

    // MARK: quitting

    func testTerminationFlushSavesAnEditStillInItsDebounce() async {
        let autosave = makeAutosave()
        autosave.select([8, 9])
        await waitUntil { self.clock.sleeping == 1 }

        await autosave.flushPendingEdit()

        XCTAssertEqual(saves, [[8, 9]])
        XCTAssertFalse(autosave.hasPendingEdit)
        clock.fire()
        await drain()
        XCTAssertEqual(saves, [[8, 9]], "the cancelled debounce saves nothing more")
    }

    func testTerminationFlushWaitsForTheSave() async {
        holds = true
        let autosave = makeAutosave()
        autosave.select([1])
        var returned = false

        let flush = Task {
            await autosave.flushPendingEdit()
            returned = true
        }
        await waitUntil { self.saves.count == 1 }
        await drain()
        XCTAssertFalse(returned)

        releaseSaves()
        await flush.value
        XCTAssertTrue(returned)
        XCTAssertFalse(autosave.hasPendingEdit)
    }

    func testAnEditMadeWhileTheFlushSavesStaysPending() async {
        holds = true
        let autosave = makeAutosave()
        autosave.select([1])
        let flush = Task { await autosave.flushPendingEdit() }
        await waitUntil { self.saves.count == 1 }

        autosave.select([1, 2])
        releaseSaves()
        await flush.value

        XCTAssertTrue(autosave.hasPendingEdit, "the older save must not mark the newer edit saved")
    }

    func testAutosaveRegistersWithTheTerminationRegistry() async {
        let registry = PendingEditRegistry()
        let autosave = makeAutosave(pendingEdits: registry)
        XCTAssertFalse(registry.hasPendingEdits)

        autosave.select([4])
        XCTAssertTrue(registry.hasPendingEdits)
        _ = await registry.flushAll()

        XCTAssertEqual(saves, [[4]])
        XCTAssertFalse(registry.hasPendingEdits)
    }

    // MARK: in-flight saves and reopened panes

    func testTheFlushAwaitsTheSaveInFlightInsteadOfResubmittingIt() async {
        holds = true
        let autosave = makeAutosave()
        autosave.select([3])
        await waitUntil { self.clock.sleeping == 1 }
        clock.fire()
        await waitUntil { self.saves.count == 1 }

        let flush = Task { await autosave.flushPendingEdit() }
        await drain()
        releaseSaves()
        await flush.value

        XCTAssertEqual(saves, [[3]], "the running save already carries the draft")
        XCTAssertFalse(autosave.hasPendingEdit)
    }

    func testTheFlushRetriesASaveThatFailed() async {
        failures = [SaveError()]
        let autosave = makeAutosave()
        autosave.select([3])
        autosave.flush()
        await waitUntil { self.errors.count == 1 }

        await autosave.flushPendingEdit()

        XCTAssertEqual(saves, [[3], [3]])
        XCTAssertFalse(autosave.hasPendingEdit)
    }

    func testSavesReachTheStoreInEditOrder() async {
        holds = true
        let autosave = makeAutosave()
        autosave.select([1])
        autosave.flush()
        await waitUntil { self.saves.count == 1 }
        autosave.select([1, 2])

        let flush = Task { await autosave.flushPendingEdit() }
        await drain()
        XCTAssertEqual(saves.count, 1, "the newer save waits for the older one")
        releaseSaves()
        await waitUntil { self.saves.count == 2 }
        releaseSaves()
        await flush.value

        XCTAssertEqual(saves, [[1], [1, 2]])
    }

    /// Leave the pane while its save is held, reopen it, edit, quit: the
    /// reopened pane gets the SAME editor, so the older draft can't be
    /// written after the newer one. Quit while the old save is still held.
    func testAReopenedPaneKeepsTheNewerEditWhenQuittingDuringTheOldSave() async {
        holds = true
        let registry = PendingEditRegistry()
        let oldPane = makeAutosave(pendingEdits: registry)
        oldPane.select([1])
        oldPane.flush()  // onDisappear
        await waitUntil { self.saves.count == 1 }

        let newPane = makeAutosave(pendingEdits: registry)
        XCTAssertTrue(oldPane === newPane, "one editor per setting")
        XCTAssertEqual(newPane.draft, [1], "the reopened pane shows the unsaved edit")
        newPane.select([2])

        let quit = Task { await registry.flushAll() }
        releaseSaves()
        await waitUntil { self.saves.count == 2 }
        releaseSaves()
        _ = await quit.value

        XCTAssertEqual(saves.last, [2])
        XCTAssertFalse(registry.hasPendingEdits)
    }

    /// The same, with the old save landing before the quit.
    func testAReopenedPaneKeepsTheNewerEditWhenTheOldSaveLandsFirst() async {
        holds = true
        let registry = PendingEditRegistry()
        let oldPane = makeAutosave(pendingEdits: registry)
        oldPane.select([1])
        oldPane.flush()
        await waitUntil { self.saves.count == 1 }
        let newPane = makeAutosave(pendingEdits: registry)
        newPane.select([2])
        releaseSaves()
        await drain()

        let quit = Task { await registry.flushAll() }
        await waitUntil { self.saves.count == 2 }
        releaseSaves()
        _ = await quit.value

        XCTAssertEqual(saves, [[1], [2]])
        XCTAssertFalse(registry.hasPendingEdits)
    }

    // MARK: helpers

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

private struct SaveError: Error {}

/// Sleeps that end only when the test fires them; a sleep cancelled before it
/// starts throws, like `Task.sleep`.
@MainActor
private final class QuietHoursClock {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var sleeping = 0
    private(set) var durations: [Duration] = []

    func sleep(_ duration: Duration) async throws {
        try Task.checkCancellation()
        durations.append(duration)
        sleeping += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func fire() {
        let pending = waiters
        waiters.removeAll()
        sleeping = 0
        pending.forEach { $0.resume() }
    }
}
