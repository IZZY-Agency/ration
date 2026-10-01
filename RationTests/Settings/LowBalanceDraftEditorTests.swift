import XCTest
@testable import Ration

/// The Low balance field's editor: a quit saves what is typed, one save at a
/// time, and unreadable text is never sent.
@MainActor
final class LowBalanceDraftEditorTests: XCTestCase {
    private let en = Locale(identifier: "en")

    func testAFocusedEditIsPendingAndAQuitSavesIt() async {
        var saved: [Int?] = []
        let registry = PendingEditRegistry()
        let editor = LowBalanceDraftEditor.editor(provider: .typeSafe, stored: nil, in: registry, save: { saved.append($0) }, onError: { _ in })
        XCTAssertFalse(registry.hasPendingEdits)
        editor.text = "5"
        XCTAssertTrue(registry.hasPendingEdits, "typed but not committed: a quit must save it")
        await registry.flushAll()
        XCTAssertEqual(saved, [500])
        XCTAssertFalse(editor.hasPendingEdit)
    }

    func testUnreadableTextRevertsAndSavesNothing() async {
        var saved: [Int?] = []
        let editor = LowBalanceDraftEditor(stored: 500, locale: en, save: { saved.append($0) }, onError: { _ in })
        editor.text = "five"
        XCTAssertFalse(editor.hasPendingEdit)
        editor.submit()
        XCTAssertEqual(editor.text, "5")
        await editor.flushPendingEdit()
        XCTAssertEqual(saved, [])
    }

    func testEmptyTurnsItOff() async {
        var saved: [Int?] = []
        let editor = LowBalanceDraftEditor(stored: 500, locale: en, save: { saved.append($0) }, onError: { _ in })
        editor.text = ""
        await editor.flushPendingEdit()
        XCTAssertEqual(saved, [nil])
    }

    /// A second edit while the first saves goes after it, never before.
    func testSavesRunOneAtATimeInOrder() async {
        var saved: [Int?] = []
        var release: CheckedContinuation<Void, Never>?
        var first = true
        let editor = LowBalanceDraftEditor(stored: nil, locale: en, save: { value in
            if first {
                first = false
                await withCheckedContinuation { release = $0 }
            }
            saved.append(value)
        }, onError: { _ in })
        editor.text = "5"
        editor.submit()
        await Task.yield()
        editor.text = "7"
        editor.submit()
        while release == nil { await Task.yield() }
        release?.resume()
        await editor.flushPendingEdit()
        XCTAssertEqual(saved, [500, 700])
    }

    func testAFailedSaveShowsTheStoredValueAgain() async {
        struct Failure: Error {}
        var errors = 0
        let editor = LowBalanceDraftEditor(stored: 500, locale: en, save: { _ in throw Failure() }, onError: { _ in errors += 1 })
        editor.text = "9"
        await editor.flushPendingEdit()
        XCTAssertEqual(errors, 1)
        XCTAssertEqual(editor.text, "5")
        XCTAssertFalse(editor.hasPendingEdit)
    }
}
