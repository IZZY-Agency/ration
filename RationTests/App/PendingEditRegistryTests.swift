import XCTest
@testable import Ration

/// Settings edits that are not on disk yet hold a quit until they are saved,
/// for at most `timeout`.
@MainActor
final class PendingEditRegistryTests: XCTestCase {
    func testNoEditorsMeansNothingPendingAndFlushReturnsAtOnce() async {
        let registry = PendingEditRegistry()

        XCTAssertFalse(registry.hasPendingEdits)
        let completed = await registry.flushAll()

        XCTAssertTrue(completed)
    }

    func testASettledEditorIsNotPending() async {
        let registry = PendingEditRegistry()
        let editor = EditorFake()
        registry.register(editor, key: "a")

        XCTAssertFalse(registry.hasPendingEdits)
        _ = await registry.flushAll()
        XCTAssertEqual(editor.flushes, 0, "nothing to save, nothing flushed")
    }

    func testFlushWaitsForEveryPendingEditor() async {
        let registry = PendingEditRegistry()
        let first = EditorFake(pending: true)
        let second = EditorFake(pending: true)
        let idle = EditorFake()
        registry.register(first, key: "first")
        registry.register(second, key: "second")
        registry.register(idle, key: "idle")

        XCTAssertTrue(registry.hasPendingEdits)
        let completed = await registry.flushAll()

        XCTAssertTrue(completed)
        XCTAssertEqual(first.flushes, 1)
        XCTAssertEqual(second.flushes, 1)
        XCTAssertEqual(idle.flushes, 0)
        XCTAssertFalse(registry.hasPendingEdits)
    }

    func testFlushDoesNotReturnBeforeTheSaveLands() async {
        let registry = PendingEditRegistry()
        let editor = EditorFake(pending: true, holds: true)
        registry.register(editor, key: "a")
        var returned = false

        let flush = Task {
            _ = await registry.flushAll()
            returned = true
        }
        await waitUntil { editor.isHeld }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertFalse(returned, "the quit must wait for the save")

        editor.release()
        await flush.value
        XCTAssertTrue(returned)
    }

    func testAStuckSaveGivesUpAfterTheTimeout() async {
        let registry = PendingEditRegistry(timeout: .milliseconds(50))
        let editor = EditorFake(pending: true, holds: true)
        registry.register(editor, key: "a")
        let started = Date()

        let completed = await registry.flushAll()

        XCTAssertFalse(completed)
        let waited = Date().timeIntervalSince(started)
        XCTAssertGreaterThanOrEqual(waited, 0.04)
        XCTAssertLessThan(waited, 1.5, "bounded by the timeout, not by the stuck save")
        editor.release()
    }

    func testARetainedEditorOutlivesItsOwnerUntilReleased() {
        let registry = PendingEditRegistry()
        var owner: EditorFake? = EditorFake(pending: true)
        weak var editor = owner
        registry.register(owner!, key: "a")

        registry.setRetained(true, editor: owner!, key: "a")
        owner = nil
        XCTAssertNotNil(editor, "held by the registry")
        XCTAssertTrue(registry.hasPendingEdits)

        registry.setRetained(false, editor: editor!, key: "a")
        XCTAssertNil(editor, "weak again once released")
    }

    func testRetainingAnEditorThatNoLongerOwnsTheKeyDoesNothing() {
        let registry = PendingEditRegistry()
        var stale: EditorFake? = EditorFake(pending: true)
        weak var weakStale = stale
        let current = EditorFake()
        registry.register(stale!, key: "a")
        registry.register(current, key: "a")

        registry.setRetained(true, editor: stale!, key: "a")
        stale = nil

        XCTAssertNil(weakStale)
        withExtendedLifetime(current) {}
    }

    func testTheDefaultTimeoutIsTwoSeconds() {
        XCTAssertEqual(PendingEditRegistry.terminationTimeout, .seconds(2))
    }

    func testAGoneEditorIsForgotten() async {
        let registry = PendingEditRegistry()
        var editor: EditorFake? = EditorFake(pending: true)
        registry.register(editor!, key: "a")
        XCTAssertTrue(registry.hasPendingEdits)

        editor = nil

        XCTAssertFalse(registry.hasPendingEdits)
    }

    func testRegisteringTwiceFlushesOnce() async {
        let registry = PendingEditRegistry()
        let editor = EditorFake(pending: true)
        registry.register(editor, key: "a")
        registry.register(editor, key: "a")

        _ = await registry.flushAll()

        XCTAssertEqual(editor.flushes, 1)
    }

    /// One editor per setting: a pane reopened while the old pane's editor
    /// is still alive (its save in flight) gets that same editor, so two
    /// drafts of one setting can never race each other to disk.
    func testALiveEditorIsReusedForItsKey() {
        let registry = PendingEditRegistry()
        var made = 0
        let first = registry.editor(forKey: "quietHours") { () -> EditorFake in
            made += 1
            return EditorFake(pending: true)
        }
        let again = registry.editor(forKey: "quietHours") { () -> EditorFake in
            made += 1
            return EditorFake()
        }

        XCTAssertTrue(first === again)
        XCTAssertEqual(made, 1)
    }

    func testAGoneEditorIsReplacedForItsKey() {
        let registry = PendingEditRegistry()
        var made = 0
        var first: EditorFake? = registry.editor(forKey: "quietHours") { () -> EditorFake in
            made += 1
            return EditorFake()
        }
        XCTAssertNotNil(first)
        first = nil

        _ = registry.editor(forKey: "quietHours") { () -> EditorFake in
            made += 1
            return EditorFake()
        }

        XCTAssertEqual(made, 2)
    }

    func testKeysAreIndependent() {
        let registry = PendingEditRegistry()
        let a = registry.editor(forKey: "label.a") { EditorFake() }
        let b = registry.editor(forKey: "label.b") { EditorFake() }

        XCTAssertFalse(a === b)
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

@MainActor
private final class EditorFake: PendingEditFlushing {
    private(set) var hasPendingEdit: Bool
    private(set) var flushes = 0
    private(set) var isHeld = false
    private let holds: Bool
    private var waiter: CheckedContinuation<Void, Never>?

    init(pending: Bool = false, holds: Bool = false) {
        hasPendingEdit = pending
        self.holds = holds
    }

    func flushPendingEdit() async {
        flushes += 1
        if holds {
            isHeld = true
            await withCheckedContinuation { waiter = $0 }
        }
        hasPendingEdit = false
    }

    func release() {
        waiter?.resume()
        waiter = nil
    }
}
