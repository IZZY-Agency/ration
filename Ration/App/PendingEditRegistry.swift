import Foundation

/// A Settings editor that saves after a debounce and may hold an edit that
/// is not on disk yet.
@MainActor
protocol PendingEditFlushing: AnyObject {
    /// True while an edit waits for its debounce, is being saved, or failed
    /// and is still the user's.
    var hasPendingEdit: Bool { get }
    /// Saves the pending edit now, skipping the debounce, and returns once the
    /// save has landed, failed or gone on to wait (e.g. for a busy account).
    func flushPendingEdit() async
}

/// Settings edits a quit must save first.
///
/// ONE editor per setting (`key`): a pane gets its editor from
/// `editor(forKey:make:)`, which hands back the live one if there is one.
/// A pane closed with a save still in flight keeps its editor alive (the
/// save's task holds it), so reopening the pane continues with that editor
/// and its draft instead of starting a second draft of the same setting —
/// two drafts would race each other to disk, and the older one could land
/// last.
///
/// Editors are held weakly: one with nothing unsaved is gone as soon as its
/// pane is. So "registered and pending" is asked of the editor itself at
/// quit time, never kept as a separate flag that could drift from it.
///
/// `requiresTerminationPreparation` asks `hasPendingEdits`, and
/// `prepareForTermination()` awaits `flushAll()`, bounded by `timeout` so a
/// save that never returns cannot hold the quit forever.
@MainActor
final class PendingEditRegistry {
    static let terminationTimeout: Duration = .seconds(2)

    typealias Sleep = @MainActor (Duration) async -> Void

    private struct Entry {
        weak var editor: (any PendingEditFlushing)?
    }

    private var entries: [String: Entry] = [:]
    private let timeout: Duration
    private let sleep: Sleep

    init(
        timeout: Duration = PendingEditRegistry.terminationTimeout,
        sleep: @escaping Sleep = { duration in try? await Task.sleep(for: duration) }
    ) {
        self.timeout = timeout
        self.sleep = sleep
    }

    /// The live editor for `key`, or a new one from `make`, registered.
    func editor<Editor: PendingEditFlushing>(
        forKey key: String,
        make: () -> Editor
    ) -> Editor {
        if let live = entries[key]?.editor as? Editor {
            return live
        }
        let editor = make()
        register(editor, key: key)
        return editor
    }

    /// Makes `editor` the one for `key`.
    func register(_ editor: any PendingEditFlushing, key: String) {
        pruneGoneEditors()
        entries[key] = Entry(editor: editor)
    }

    var hasPendingEdits: Bool {
        !pendingEditors().isEmpty
    }

    /// Flushes every pending edit at once and waits for all of them, or for
    /// `timeout`, whichever comes first. Returns false on a timeout; the
    /// saves still running are left to finish if the process lives on.
    ///
    /// Unstructured tasks, not a task group: a group waits for all of its
    /// children before it returns, so a stuck save would defeat the timeout.
    @discardableResult
    func flushAll() async -> Bool {
        let editors = pendingEditors()
        guard !editors.isEmpty else { return true }
        let outcome = FlushOutcome()
        let timeout = timeout
        let sleep = sleep
        return await withCheckedContinuation { continuation in
            outcome.continuation = continuation
            let flushes: [Task<Void, Never>] = editors.map { editor in
                Task { await editor.flushPendingEdit() }
            }
            let timer = Task {
                await sleep(timeout)
                outcome.finish(false)
            }
            Task {
                for flush in flushes {
                    await flush.value
                }
                timer.cancel()
                outcome.finish(true)
            }
        }
    }

    private func pendingEditors() -> [any PendingEditFlushing] {
        pruneGoneEditors()
        var editors: [any PendingEditFlushing] = []
        for entry in entries.values {
            guard let editor = entry.editor, editor.hasPendingEdit else { continue }
            editors.append(editor)
        }
        return editors
    }

    private func pruneGoneEditors() {
        entries = entries.filter { $0.value.editor != nil }
    }
}

/// Resumes `flushAll()` exactly once: whichever of "all saved" and the
/// timeout comes first wins.
@MainActor
private final class FlushOutcome {
    var continuation: CheckedContinuation<Bool, Never>?

    func finish(_ completed: Bool) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: completed)
    }
}
