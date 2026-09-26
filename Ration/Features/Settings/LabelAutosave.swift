import Foundation

/// The account label field's model: owns the field text and saves it as the
/// user types.
///
/// Every change to `text` is an edit. The label is saved once typing pauses
/// for `debounce`, or at once on `flush()` (blur, Return, pane closing). The
/// rules that keep that from racing the store:
///
/// * At most ONE save runs at a time. `AppModel.renameAccount` rejects a
///   second mutation of the same account with `operationInProgress`, so an
///   edit made while a save runs waits for it; only the newest waiting value
///   is kept, and it still waits out its own debounce.
/// * An edit is compared with what the store WILL hold once the running save
///   lands, not with the published label, which still lags. Otherwise typing
///   "Work2" and backspacing to "Work" would skip the second save and leave
///   "Work2" stored.
/// * The text follows the store only when nothing of the user's is unsaved
///   (nothing waiting, running, or failed). A store change made elsewhere —
///   e.g. a re-sign-in that sets a new label — is shown at once, even in a
///   focused field, so a later blur can't save the stale text over it. The
///   echo of this model's own save is not shown while focused, so a trailing
///   space the user just typed isn't trimmed away under the caret.
/// * A save rejected because the account is busy (`operationInProgress`,
///   e.g. a resume holds the account through its refresh) is not an error:
///   it is retried every `busyRetryInterval`, up to `busyRetryLimit` times.
///   The waiting task keeps this model alive, so the edit still lands after
///   the pane closes or another account is selected.
/// * Any other failure is reported and keeps the user's text (retried on the
///   next flush) instead of reverting it. A later successful save clears the
///   report.
///
/// Blank text is never saved; the store rejects it.
///
/// A quit saves an unsettled edit first: panes get the model from
/// `editor(accountID:…)`, which keeps ONE model per account in the app's
/// `PendingEditRegistry` (a pane reopened while a save is in flight
/// continues with it), and `flushPendingEdit()` skips the debounce and waits
/// for the save.
@MainActor
final class LabelAutosave: ObservableObject, PendingEditFlushing {
    typealias Save = @MainActor (String) async throws -> Void
    typealias Sleep = @MainActor (Duration) async throws -> Void

    static let debounce: Duration = .milliseconds(400)
    static let busyRetryInterval: Duration = .seconds(1)

    @Published var text: String {
        didSet { if text != oldValue { edit() } }
    }

    private let save: Save
    /// Replaced when a reopened pane takes this model over, so errors reach
    /// the Settings window that is showing now.
    private var onError: @MainActor (Error?) -> Void
    private let sleep: Sleep
    private let busyRetryLimit: Int

    /// The label the store is known to hold.
    private var stored: String
    /// The value of the save currently running.
    private var saving: String?
    /// The newest edit not yet handed to `save`. Eligible to save once no
    /// debounce is waiting.
    private var pending: String?
    /// The newest save failed and no later edit has replaced it.
    private var failed = false
    private var isFocused = false
    private var busyRetries = 0
    private var reportedError = false
    /// A debounce or a busy-retry wait. While it runs, `pending` is not yet
    /// eligible to save.
    private var debounceTask: Task<Void, Never>?
    /// The save currently running (`saving`'s task).
    private var saveTask: Task<Void, Never>?

    init(
        stored: String,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        busyRetryLimit: Int = 120,
        save: @escaping Save,
        onError: @escaping @MainActor (Error?) -> Void
    ) {
        self.text = stored
        self.stored = stored
        self.sleep = sleep
        self.busyRetryLimit = busyRetryLimit
        self.save = save
        self.onError = onError
    }

    /// The account's label model: the live one if a pane left it with work
    /// in flight, otherwise a new one. Without a registry (previews, tests),
    /// always a new one.
    static func editor(
        accountID: UUID,
        stored: String,
        in registry: PendingEditRegistry?,
        save: @escaping Save,
        onError: @escaping @MainActor (Error?) -> Void
    ) -> LabelAutosave {
        guard let registry else {
            return LabelAutosave(stored: stored, save: save, onError: onError)
        }
        let editor = registry.editor(forKey: "label.\(accountID.uuidString)") {
            LabelAutosave(stored: stored, save: save, onError: onError)
        }
        editor.onError = onError
        return editor
    }

    /// True when nothing of the user's is waiting, being saved, or failed.
    var isSettled: Bool { saving == nil && pending == nil && !failed }

    var hasPendingEdit: Bool { !isSettled }

    /// For a quit: saves the current text now (retrying a failed save), then
    /// waits until no save is running and none is waiting its turn. A busy
    /// account's retry wait counts as waiting; the caller bounds the total.
    func flushPendingEdit() async {
        flush()
        while let task = saveTask ?? debounceTask {
            await task.value
        }
    }

    /// What the store will hold once the running save, if any, lands.
    private var target: String { saving ?? stored }

    func focusChanged(_ focused: Bool) {
        isFocused = focused
        if !focused { flush() }
    }

    /// Saves the current text now instead of after the debounce.
    func flush() {
        edit(debounced: false)
        startNextSave()
        showStoredIfIdle()
    }

    /// The store published `label`.
    func storeDidChange(_ label: String) {
        // When settled, every save of ours has landed and updated `stored`,
        // so a different label can only come from elsewhere.
        let changedElsewhere = isSettled && label != stored
        stored = label
        if changedElsewhere {
            text = label
        } else {
            showStoredIfIdle()
        }
    }

    private func edit(debounced: Bool = true) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        failed = false
        cancelDebounce()
        if trimmed.isEmpty || trimmed == target {
            pending = nil
        } else {
            pending = trimmed
            if debounced { scheduleSave() }
        }
    }

    private func scheduleSave(after delay: Duration = LabelAutosave.debounce) {
        debounceTask = Task { [sleep] in
            do { try await sleep(delay) } catch { return }
            guard !Task.isCancelled else { return }
            debounceTask = nil
            startNextSave()
        }
    }

    private func cancelDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    /// Holds `self` until the chain finishes, so an edit flushed as the pane
    /// closes is still saved.
    private func startNextSave() {
        guard saving == nil, debounceTask == nil, let value = pending else { return }
        pending = nil
        saving = value
        saveTask = Task {
            do {
                try await save(value)
                stored = value
                busyRetries = 0
                if reportedError {
                    reportedError = false
                    onError(nil)
                }
            } catch AccountStoreError.operationInProgress where busyRetries < busyRetryLimit {
                busyRetries += 1
                // A newer edit, if any, supersedes this value.
                if pending == nil { pending = value }
                if debounceTask == nil { scheduleSave(after: Self.busyRetryInterval) }
            } catch {
                busyRetries = 0
                failed = pending == nil
                reportedError = true
                onError(error)
            }
            saving = nil
            saveTask = nil
            startNextSave()
            showStoredIfIdle()
        }
    }

    /// Shows the stored label (trimmed, or restored after the field was
    /// cleared) once editing is over.
    private func showStoredIfIdle() {
        guard !isFocused, isSettled, text != stored else { return }
        text = stored
    }
}
