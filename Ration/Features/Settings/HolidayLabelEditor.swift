import Foundation

/// A holiday range's label field: owns the text and commits it when the field
/// loses focus (or on Return), never per keystroke.
///
/// * Saves run one at a time, in commit order, and an edit is compared with
///   what the store WILL hold once the running save lands — typing "A",
///   committing, then going back to the old label still saves the old label.
/// * A failed save is reported and keeps the user's text, so the next commit
///   (or a quit) tries again. The edit outlives its pane: while anything is
///   unsaved the `PendingEditRegistry` holds this editor strongly, so a
///   reopened pane shows the edited text and the error again
///   (`paneAppeared()`), and a quit still saves it.
/// * The text follows the store only while the user has nothing uncommitted.
///
/// Panes get the model from `editor(holidayID:…)`, which keeps ONE per
/// holiday in the app's `PendingEditRegistry`, and `flushPendingEdit()`
/// commits the text and waits for the save.
@MainActor
final class HolidayLabelEditor: ObservableObject, PendingEditFlushing {
    typealias Save = @MainActor (String) async throws -> Void

    @Published var text: String {
        didSet { updateRetention() }
    }

    /// The label the store is known to hold.
    private var stored: String
    /// The value of the newest save handed to the store and not yet landed.
    private var submitted: String?
    private var saveTask: Task<Void, Never>?
    private var runningSaves = 0
    /// The newest save's failure, until a save succeeds.
    private var lastError: Error?
    private let save: Save
    /// Replaced when a reopened pane takes this model over.
    private var onError: @MainActor (Error) -> Void
    /// Tells the registry whether to hold this editor strongly.
    private var retain: (@MainActor (Bool) -> Void)?
    private var isRetained = false

    init(
        stored: String,
        save: @escaping Save,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        text = stored
        self.stored = stored
        self.save = save
        self.onError = onError
    }

    /// The holiday's label model: the live one if a pane left it with work in
    /// flight or unsaved, otherwise a new one. Without a registry (previews,
    /// tests), always a new one.
    static func editor(
        holidayID: UUID,
        stored: String,
        in registry: PendingEditRegistry?,
        save: @escaping Save,
        onError: @escaping @MainActor (Error) -> Void
    ) -> HolidayLabelEditor {
        guard let registry else {
            return HolidayLabelEditor(stored: stored, save: save, onError: onError)
        }
        let key = registryKey(holidayID: holidayID)
        let editor = registry.editor(forKey: key) {
            HolidayLabelEditor(stored: stored, save: save, onError: onError)
        }
        editor.onError = onError
        editor.retain = { [weak registry, unowned editor] retained in
            registry?.setRetained(retained, editor: editor, key: key)
        }
        return editor
    }

    /// The holiday's key in the `PendingEditRegistry`.
    static func registryKey(holidayID: UUID) -> String {
        "holidayLabel.\(holidayID.uuidString)"
    }

    /// What the store will hold once the running saves land.
    private var target: String { submitted ?? stored }

    var hasPendingEdit: Bool { text != target || saveTask != nil }

    /// A save has not landed (or failed) yet.
    var isSaving: Bool { saveTask != nil }

    func focusChanged(_ focused: Bool) {
        if !focused { commit() }
    }

    /// A pane shows this editor: reports again a failed save it still holds.
    func paneAppeared() {
        guard saveTask == nil, let lastError, hasPendingEdit else { return }
        onError(lastError)
    }

    /// Hands the text to the store if it differs from what the store will
    /// hold.
    func commit() {
        let value = text
        guard value != target else { return }
        submitted = value
        runningSaves += 1
        let previous = saveTask
        saveTask = Task {
            await previous?.value
            await persist(value)
        }
        updateRetention()
    }

    /// For a quit: commits the text, then waits for every save to finish.
    func flushPendingEdit() async {
        commit()
        while let task = saveTask {
            await task.value
        }
    }

    /// The store published `label`.
    func storeDidChange(_ label: String) {
        guard saveTask == nil else { return }
        let unchanged = text == stored
        stored = label
        if unchanged {
            text = label
        } else {
            updateRetention()
        }
    }

    private func persist(_ value: String) async {
        do {
            try await save(value)
            stored = value
            lastError = nil
        } catch {
            lastError = error
            onError(error)
        }
        runningSaves -= 1
        guard runningSaves == 0 else { return }
        submitted = nil
        saveTask = nil
        updateRetention()
    }

    private func updateRetention() {
        let pending = hasPendingEdit
        guard pending != isRetained, let retain else { return }
        isRetained = pending
        retain(pending)
    }
}
