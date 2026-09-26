import Foundation

/// The quiet-hours grid's model: owns the draft and saves it once the grid
/// stops changing for `debounce`.
///
/// `AppSettings` publishes only AFTER a successful save, so the grid never
/// reads the published value, mutates it and writes the whole thing back.
/// Instead every change updates the local `draft` AND bumps `draftRevision`
/// in the same call, then schedules a debounced save. The draft counts as
/// saved only once the save carrying the CURRENT revision succeeds, so a
/// failed or superseded save leaves it dirty (and retried on the next flush)
/// rather than silently dropping edits.
///
/// Saves reach the store in edit order: each waits for the previous one,
/// and a flush waits for a save that already carries the current draft
/// instead of submitting it again.
///
/// It lives above the view so a quit can reach it: panes get it from
/// `editor(…)`, which keeps ONE per app in the `PendingEditRegistry` (a pane
/// reopened while a save is in flight continues with it), and
/// `flushPendingEdit()` skips the debounce and waits for the save.
@MainActor
final class QuietHoursAutosave: ObservableObject, PendingEditFlushing {
    typealias Save = @MainActor ([Int]) async throws -> Void
    typealias Sleep = @MainActor (Duration) async throws -> Void

    static let debounce: Duration = .milliseconds(400)

    @Published private(set) var draft: Set<Int>

    private var draftRevision = 0
    private var savedRevision = 0
    private var debounceTask: Task<Void, Never>?
    /// The newest save handed to the store, and the revision it carries
    /// (nil once it failed, so a flush tries again).
    private var saveTask: Task<Void, Never>?
    private var saveTaskRevision: Int?
    private let persist: Save
    private let sleep: Sleep
    /// Replaced when a reopened pane takes this model over.
    private var onError: @MainActor (Error) -> Void

    init(
        stored: [Int],
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        save: @escaping Save,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        draft = Set(stored)
        self.sleep = sleep
        self.persist = save
        self.onError = onError
    }

    /// The app's quiet-hours model: the live one if a pane left it with work
    /// in flight, otherwise a new one. Without a registry (previews, tests),
    /// always a new one.
    static func editor(
        stored: [Int],
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        in registry: PendingEditRegistry?,
        save: @escaping Save,
        onError: @escaping @MainActor (Error) -> Void
    ) -> QuietHoursAutosave {
        guard let registry else {
            return QuietHoursAutosave(stored: stored, sleep: sleep, save: save, onError: onError)
        }
        let editor = registry.editor(forKey: "quietHours") {
            QuietHoursAutosave(stored: stored, sleep: sleep, save: save, onError: onError)
        }
        editor.onError = onError
        return editor
    }

    /// The draft differs from what the store is known to hold.
    var hasPendingEdit: Bool { draftRevision != savedRevision }

    /// The grid changed. Value and revision advance together, so no save can
    /// observe one without the other.
    func select(_ cells: Set<Int>) {
        guard cells != draft else { return }
        draft = cells
        draftRevision += 1
        scheduleSave()
    }

    /// The store published `cells`. Adopted only while nothing of the user's
    /// is unsaved — a dirty draft is never clobbered. Neither bumps the
    /// revision nor schedules a save.
    func storeDidChange(_ cells: [Int]) {
        guard !hasPendingEdit else { return }
        draft = Set(cells)
    }

    /// The pane is going away: saves a pending edit now instead of after the
    /// debounce, without waiting for it.
    func flush() {
        Task { await flushPendingEdit() }
    }

    /// Saves a pending edit now and returns once that save has landed or
    /// failed. A save already carrying the current draft is awaited, not
    /// submitted again.
    func flushPendingEdit() async {
        cancelDebounce()
        guard hasPendingEdit else { return }
        if saveTaskRevision != draftRevision {
            submitSave()
        }
        await saveTask?.value
    }

    private func scheduleSave() {
        cancelDebounce()
        debounceTask = Task { [sleep] in
            do { try await sleep(Self.debounce) } catch { return }
            guard !Task.isCancelled else { return }
            debounceTask = nil
            submitSave()
        }
    }

    /// Hands the current draft to the store after the previous save, so
    /// saves land in edit order.
    private func submitSave() {
        let revision = draftRevision
        let value = draft
        let previous = saveTask
        saveTaskRevision = revision
        saveTask = Task {
            await previous?.value
            await save(revision: revision, value: value)
        }
    }

    private func cancelDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Persists `value` and marks the draft clean ONLY if `revision` is still
    /// the newest — a slow save that lands after a newer edit must not declare
    /// the newer edit saved.
    private func save(revision: Int, value: Set<Int>) async {
        do {
            try await persist(Array(value))
            if revision == draftRevision {
                savedRevision = revision
            }
        } catch {
            if saveTaskRevision == revision {
                saveTaskRevision = nil
            }
            onError(error)
        }
    }
}
