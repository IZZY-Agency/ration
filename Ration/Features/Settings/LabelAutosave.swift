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
@MainActor
final class LabelAutosave: ObservableObject {
    typealias Save = @MainActor (String) async throws -> Void
    typealias Sleep = @MainActor (Duration) async throws -> Void

    static let debounce: Duration = .milliseconds(400)
    static let busyRetryInterval: Duration = .seconds(1)

    @Published var text: String {
        didSet { if text != oldValue { edit() } }
    }

    private let save: Save
    private let onError: @MainActor (Error?) -> Void
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

    /// True when nothing of the user's is waiting, being saved, or failed.
    var isSettled: Bool { saving == nil && pending == nil && !failed }

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
        Task {
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
