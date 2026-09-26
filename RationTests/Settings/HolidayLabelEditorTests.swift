import XCTest
@testable import Ration

/// A holiday's label field: commits on blur, one save at a time, keeps a
/// failed edit, and tells a quit it has something unsaved.
@MainActor
final class HolidayLabelEditorTests: XCTestCase {
    private var saves: [String] = []
    private var errors: [Error] = []
    private var failNext = false
    private var holds = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override func setUp() async throws {
        saves = []
        errors = []
        failNext = false
        holds = false
        waiters = []
    }

    private func makeEditor(stored: String = "Winter") -> HolidayLabelEditor {
        HolidayLabelEditor.editor(
            holidayID: UUID(),
            stored: stored,
            in: nil,
            save: { [weak self] label in
                guard let self else { return }
                try await self.save(label)
            },
            onError: { [weak self] error in
                self?.errors.append(error)
            }
        )
    }

    private func save(_ label: String) async throws {
        saves.append(label)
        if holds {
            await withCheckedContinuation { waiters.append($0) }
        }
        if failNext {
            failNext = false
            throw LabelSaveError()
        }
    }

    func testTypingSavesNothingUntilTheFieldLosesFocus() async {
        let editor = makeEditor()

        editor.focusChanged(true)
        editor.text = "Summer"
        await drain()
        XCTAssertEqual(saves, [])
        XCTAssertTrue(editor.hasPendingEdit, "a quit must know about typed text")

        editor.focusChanged(false)
        await editor.flushPendingEdit()
        XCTAssertEqual(saves, ["Summer"])
        XCTAssertFalse(editor.hasPendingEdit)
    }

    func testAQuitSavesTheFocusedFieldsText() async {
        let editor = makeEditor()
        editor.focusChanged(true)
        editor.text = "Summer"

        await editor.flushPendingEdit()

        XCTAssertEqual(saves, ["Summer"])
        XCTAssertFalse(editor.hasPendingEdit)
    }

    func testAnUnchangedLabelIsNotSaved() async {
        let editor = makeEditor()
        XCTAssertFalse(editor.hasPendingEdit)

        await editor.flushPendingEdit()

        XCTAssertEqual(saves, [])
    }

    func testAFailedSaveKeepsTheTextForTheNextCommit() async {
        let editor = makeEditor()
        failNext = true
        editor.text = "Summer"

        await editor.flushPendingEdit()
        XCTAssertEqual(errors.count, 1)
        XCTAssertEqual(editor.text, "Summer")
        XCTAssertTrue(editor.hasPendingEdit)

        await editor.flushPendingEdit()
        XCTAssertEqual(saves, ["Summer", "Summer"])
        XCTAssertFalse(editor.hasPendingEdit)
    }

    func testGoingBackToTheOldLabelWhileASaveRunsSavesItAgain() async {
        let editor = makeEditor()
        holds = true
        editor.text = "Summer"
        editor.commit()
        await waitUntil { self.waiters.count == 1 }

        editor.text = "Winter"
        editor.commit()
        holds = false
        releaseSaves()
        await editor.flushPendingEdit()

        XCTAssertEqual(saves, ["Summer", "Winter"])
    }

    func testTheStoreIsShownOnlyWhileNothingIsUncommitted() {
        let editor = makeEditor()

        editor.storeDidChange("Spring")
        XCTAssertEqual(editor.text, "Spring")

        editor.text = "Mine"
        editor.storeDidChange("Autumn")
        XCTAssertEqual(editor.text, "Mine")
    }

    // MARK: helpers

    private func releaseSaves() {
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
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

private struct LabelSaveError: Error {}
