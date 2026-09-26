import Foundation

/// Which field of a warning/critical row holds keyboard focus.
enum ThresholdField: Hashable, Sendable {
    case warning
    case critical
}

/// Why a threshold field's text would not be saved as shown. The field gets a
/// red border and, for VoiceOver, `accessibilityNote`.
enum ThresholdFieldFlag: Equatable, Sendable {
    /// The text is not a valid value; it is never saved.
    case invalid
    /// Saving turns the value into this text, as the field would show it.
    /// Empty when the tier is turned off (a Cursor warning not below the
    /// critical amount).
    case adjusted(to: String)

    /// What VoiceOver says about the flagged field.
    func accessibilityNote(locale: Locale = .current) -> String {
        switch self {
        case .invalid:
            return LocalizedStringResource.alertsFieldInvalid.string(in: locale)
        case .adjusted(let text) where text.isEmpty:
            return LocalizedStringResource.alertsFieldWillTurnOff.string(in: locale)
        case .adjusted(let text):
            return LocalizedStringResource.alertsFieldWillAdjust(text).string(in: locale)
        }
    }

    /// The note for a field that may not be flagged: `nil` while its text
    /// will be saved as shown.
    static func accessibilityNote(
        _ flag: ThresholdFieldFlag?,
        locale: Locale = .current
    ) -> String? {
        guard let flag else { return nil }
        return flag.accessibilityNote(locale: locale)
    }
}

/// The model behind a warning/critical row in the Alerts pane (a provider ×
/// window percent row, or Cursor's dollar spend): owns both fields' text and
/// commits them as ONE draft.
///
/// * Both fields go to the store together and are canonicalised once, so
///   typing warning 95 and critical 99 over 75/90 gives 95/99 whichever field
///   was typed first. Committing one field at a time made that 89/99 in one
///   order and 95/99 in the other.
/// * The draft is saved once typing stops for `debounce`, and at once when
///   focus leaves the row, on Return, or on quit — never merely because focus
///   moved from one of the row's fields to the other.
/// * A field whose text would not be saved as shown is `flagged`: text that
///   does not parse, or a value the pair's canonical form would change —
///   the field typed in or its untouched sibling (critical "9", the first
///   digit of 99, would pull warning 75 down to 8). The debounce saves only a
///   draft whose save changes nothing on screen: nothing flagged and every
///   typed text already in its display form ("9.00", not "9"). Anything else
///   waits; leaving the row, Return or a quit commits it as one draft
///   (canonicalised, or invalid text dropped).
/// * Only fields the user changed are sent (`FieldEdit.set`); the other is
///   `.keep`, read from the store inside its serialized mutation.
/// * Text that does not parse (`Fields.parse`) or equals the stored value is
///   not sent on a commit; the field shows the stored value again. That is
///   the same validation a blur always used, and a quit uses it too.
/// * Both fields are always drawn from the pair the store RETURNS, not from
///   what was typed: a failed save puts the stored value back, and a
///   canonicalised sibling is shown even while that field has focus. Only a
///   field the user has changed since it was last drawn keeps its text.
/// * Saves run one at a time, in commit order.
///
/// A quit saves an uncommitted row first: panes get the model from
/// `editor(key:…)` (via `SettingsEditors`), which keeps ONE per row in the
/// app's `PendingEditRegistry`, and `flushPendingEdit()` commits the draft and
/// waits for the save.
@MainActor
final class ThresholdDraftEditor<Pair: Equatable, Value: Equatable & Sendable>: ObservableObject, PendingEditFlushing {
    typealias Commit = @MainActor (FieldEdit<Value>, FieldEdit<Value>) async throws -> Pair
    typealias Sleep = @MainActor (Duration) async throws -> Void

    static var debounce: Duration { .milliseconds(700) }

    /// How a row reads, draws and parses its two fields.
    struct Fields {
        let warning: (Pair) -> Value
        let critical: (Pair) -> Value
        let text: (Value) -> String
        /// `nil` when the text is not a valid value.
        let parse: (String) -> Value?
        /// The pair the store makes of a warning and a critical value.
        let canonical: (Value, Value) -> Pair
    }

    @Published var warningText: String {
        didSet { if warningText != oldValue { textDidChange() } }
    }
    @Published var criticalText: String {
        didSet { if criticalText != oldValue { textDidChange() } }
    }
    /// Fields whose text would not be saved as shown, and why.
    @Published private(set) var flagged: [ThresholdField: ThresholdFieldFlag] = [:]

    /// The pair the store holds, as far as this row knows.
    private(set) var stored: Pair
    /// What each field was last drawn as. A field whose text differs has
    /// been changed by the user since.
    private var drawnWarning: String
    private var drawnCritical: String
    /// The newest save; each waits for the one before it.
    private var saveTask: Task<Void, Never>?
    private var runningSaves = 0
    private var debounceTask: Task<Void, Never>?
    private let fields: Fields
    private let sleep: Sleep
    private let commit: Commit
    /// Replaced when a reopened pane takes this model over.
    private var onError: @MainActor (Error) -> Void

    init(
        stored: Pair,
        fields: Fields,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        commit: @escaping Commit,
        onError: @escaping @MainActor (Error) -> Void
    ) {
        self.stored = stored
        self.fields = fields
        self.sleep = sleep
        self.commit = commit
        self.onError = onError
        let warning = fields.text(fields.warning(stored))
        let critical = fields.text(fields.critical(stored))
        warningText = warning
        criticalText = critical
        drawnWarning = warning
        drawnCritical = critical
    }

    /// The row's model: the live one if a pane left it with work in flight,
    /// otherwise a new one. Without a registry (previews, tests), always a
    /// new one.
    static func editor(
        key: String,
        stored: Pair,
        fields: Fields,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        in registry: PendingEditRegistry?,
        commit: @escaping Commit,
        onError: @escaping @MainActor (Error) -> Void
    ) -> ThresholdDraftEditor {
        guard let registry else {
            return ThresholdDraftEditor(stored: stored, fields: fields, sleep: sleep, commit: commit, onError: onError)
        }
        let editor = registry.editor(forKey: key) {
            ThresholdDraftEditor(stored: stored, fields: fields, sleep: sleep, commit: commit, onError: onError)
        }
        editor.onError = onError
        return editor
    }

    private var warningChanged: Bool { warningText != drawnWarning }
    private var criticalChanged: Bool { criticalText != drawnCritical }

    var hasPendingEdit: Bool { warningChanged || criticalChanged || isSaving }

    /// A committed draft has not landed (or failed) yet.
    var isSaving: Bool { saveTask != nil }

    /// Focus moved to `field`; `nil` means it left the row, which commits.
    func focusChanged(to field: ThresholdField?) {
        if field == nil { submit() }
    }

    /// Commits the draft now: both changed fields, as one.
    func submit() {
        cancelDebounce()
        let warning = edit(warningText, drawn: drawnWarning, current: fields.warning(stored))
        let critical = edit(criticalText, drawn: drawnCritical, current: fields.critical(stored))
        // Invalid or unchanged text is not sent: show the stored value again.
        if warning == .keep, warningChanged { drawWarning() }
        if critical == .keep, criticalChanged { drawCritical() }
        guard warning != .keep || critical != .keep else {
            refreshFlags()
            return
        }
        // The submitted text becomes the baseline, so a field the user changes
        // while this save runs keeps its newer text when the save lands.
        drawnWarning = warningText
        drawnCritical = criticalText
        // A redraw above may have restarted the debounce; this commit covers it.
        cancelDebounce()
        let previous = saveTask
        runningSaves += 1
        saveTask = Task {
            await previous?.value
            await save(warning: warning, critical: critical)
        }
        refreshFlags()
    }

    /// For a quit: commits the draft, then waits for every save to finish.
    func flushPendingEdit() async {
        submit()
        while let task = saveTask {
            await task.value
        }
    }

    /// The store published `pair`. While a save runs, its returned pair is
    /// drawn when it lands; otherwise the unchanged fields are drawn now.
    func storeDidChange(_ pair: Pair) {
        stored = pair
        guard saveTask == nil else { return }
        drawUnchangedFields()
        refreshFlags()
    }

    /// `.keep` for text the user has not changed, text that does not parse,
    /// and — when no save is running — the value already stored. While a save
    /// runs, `stored` is not yet what the store will hold, so a changed field
    /// is always sent.
    private func edit(_ text: String, drawn: String, current: Value) -> FieldEdit<Value> {
        guard text != drawn, let value = fields.parse(text) else { return .keep }
        if saveTask == nil, value == current { return .keep }
        return .set(value)
    }

    /// The user typed: flags are refreshed and the debounce restarts. A draw
    /// (text set to what is stored) leaves no changed field and schedules
    /// nothing.
    private func textDidChange() {
        refreshFlags()
        cancelDebounce()
        guard warningChanged || criticalChanged else { return }
        debounceTask = Task { [sleep] in
            do { try await sleep(Self.debounce) } catch { return }
            guard !Task.isCancelled else { return }
            debounceTask = nil
            autosave()
        }
    }

    /// Typing stopped: saves the draft only if the save would change nothing
    /// on screen — neither field canonicalised (`flagged` is empty) and no
    /// typed text reformatted. Anything else waits for the user to finish, or
    /// for the row to be left, Return or a quit, which commit it as usual.
    private func autosave() {
        guard flagged.isEmpty, changedTextIsInDisplayForm else { return }
        submit()
    }

    private func cancelDebounce() {
        debounceTask?.cancel()
        debounceTask = nil
    }

    private func save(warning: FieldEdit<Value>, critical: FieldEdit<Value>) async {
        do {
            stored = try await commit(warning, critical)
        } catch {
            onError(error)
        }
        runningSaves -= 1
        guard runningSaves == 0 else { return }
        saveTask = nil
        drawUnchangedFields()
        refreshFlags()
    }

    /// Draws every field the user has not changed since it was last drawn
    /// from `stored` — after a failed save that is the value still stored.
    private func drawUnchangedFields() {
        if !warningChanged { drawWarning() }
        if !criticalChanged { drawCritical() }
    }

    // The baseline is set before the text, so the text's `didSet` sees an
    // unchanged field and schedules no save.
    private func drawWarning() {
        let text = fields.text(fields.warning(stored))
        drawnWarning = text
        warningText = text
    }

    private func drawCritical() {
        let text = fields.text(fields.critical(stored))
        drawnCritical = text
        criticalText = text
    }

    private func refreshFlags() {
        let flags = currentFlags()
        if flags != flagged { flagged = flags }
    }

    private func currentFlags() -> [ThresholdField: ThresholdFieldFlag] {
        let warning = typedValue(warningText, drawn: drawnWarning)
        let critical = typedValue(criticalText, drawn: drawnCritical)
        var flags: [ThresholdField: ThresholdFieldFlag] = [:]
        if warning == .invalid { flags[.warning] = .invalid }
        if critical == .invalid { flags[.critical] = .invalid }
        guard flags.isEmpty else { return flags }
        let warningValue = warning.value(or: fields.warning(stored))
        let criticalValue = critical.value(or: fields.critical(stored))
        let pair = fields.canonical(warningValue, criticalValue)
        let savedWarning = fields.warning(pair)
        let savedCritical = fields.critical(pair)
        // Either field — the one typed in or its untouched sibling — may be
        // changed by the canonical form.
        if savedWarning != warningValue {
            flags[.warning] = .adjusted(to: fields.text(savedWarning))
        }
        if savedCritical != criticalValue {
            flags[.critical] = .adjusted(to: fields.text(savedCritical))
        }
        return flags
    }

    /// Every changed field's text is exactly what the field will show once
    /// saved ("9.00", not "9"; "75", not "075"), so a save cannot reformat
    /// the text under the caret.
    private var changedTextIsInDisplayForm: Bool {
        isInDisplayForm(warningText, drawn: drawnWarning) && isInDisplayForm(criticalText, drawn: drawnCritical)
    }

    private func isInDisplayForm(_ text: String, drawn: String) -> Bool {
        guard text != drawn else { return true }
        guard let value = fields.parse(text) else { return false }
        return fields.text(value) == text
    }

    private func typedValue(_ text: String, drawn: String) -> TypedValue {
        guard text != drawn else { return .unchanged }
        guard let value = fields.parse(text) else { return .invalid }
        return .typed(value)
    }

    private enum TypedValue: Equatable {
        case unchanged
        case invalid
        case typed(Value)

        func value(or current: Value) -> Value {
            switch self {
            case .typed(let value): return value
            case .unchanged, .invalid: return current
            }
        }
    }
}

/// The two kinds of row the Alerts pane edits.
@MainActor
enum ThresholdDraftFields {
    /// Percent rows: whole numbers (`Int(_:)`), canonicalised by
    /// `ThresholdPair`.
    static var percent: ThresholdDraftEditor<ThresholdPair, Int>.Fields {
        ThresholdDraftEditor<ThresholdPair, Int>.Fields(
            warning: { pair in pair.warningPercent },
            critical: { pair in pair.criticalPercent },
            text: { value in String(value) },
            parse: { text in Int(text) },
            canonical: { warning, critical in
                ThresholdPair(warningPercent: warning, criticalPercent: critical)
            }
        )
    }

    /// Cursor's dollar fields, in cents; blank turns a tier off. Parsing is
    /// `CursorSpendFieldParsing`'s, in the app language.
    static var cursorSpend: ThresholdDraftEditor<SpendThresholds, Int?>.Fields {
        ThresholdDraftEditor<SpendThresholds, Int?>.Fields(
            warning: { spend in spend.warningCents },
            critical: { spend in spend.criticalCents },
            text: { cents in CursorSpendFieldParsing.dollarsText(fromCents: cents) },
            parse: { text in CursorSpendFieldParsing.parsedCents(text) },
            canonical: { warning, critical in
                SpendThresholds(warningCents: warning, criticalCents: critical)
            }
        )
    }

    static func percentKey(_ row: AlertsGridRow) -> String {
        "alertThresholds.\(row.id)"
    }

    static let cursorSpendKey = "alertThresholds.\(AppSettingsData.cursorSpendKey)"
}

/// How the Settings panes build their editors, and how those editors reach
/// the model. `SettingsView` and the panes use these, and so do the tests, so
/// a broken key, registry or model binding fails a test.
@MainActor
enum SettingsEditors {
    typealias ThresholdsSave = (FieldEdit<Int>, FieldEdit<Int>, Provider, UsageWindowKind) async throws -> ThresholdPair
    typealias CursorSpendSave = (FieldEdit<Int?>, FieldEdit<Int?>) async throws -> SpendThresholds
    typealias HolidayLabelSave = (UUID, String) async throws -> Void

    static func thresholdRow(
        _ row: AlertsGridRow,
        stored: ThresholdPair,
        in registry: PendingEditRegistry?,
        save: @escaping ThresholdsSave,
        onError: @escaping (Error) -> Void
    ) -> ThresholdDraftEditor<ThresholdPair, Int> {
        let provider = row.provider
        let window = row.window
        return ThresholdDraftEditor.editor(
            key: ThresholdDraftFields.percentKey(row),
            stored: stored,
            fields: ThresholdDraftFields.percent,
            in: registry,
            commit: { warning, critical in
                try await save(warning, critical, provider, window)
            },
            onError: { error in
                onError(error)
            }
        )
    }

    static func cursorSpend(
        stored: SpendThresholds,
        in registry: PendingEditRegistry?,
        save: @escaping CursorSpendSave,
        onError: @escaping (Error) -> Void
    ) -> ThresholdDraftEditor<SpendThresholds, Int?> {
        ThresholdDraftEditor.editor(
            key: ThresholdDraftFields.cursorSpendKey,
            stored: stored,
            fields: ThresholdDraftFields.cursorSpend,
            in: registry,
            commit: { warning, critical in
                try await save(warning, critical)
            },
            onError: { error in
                onError(error)
            }
        )
    }

    static func holidayLabel(
        _ holiday: HolidayRange,
        in registry: PendingEditRegistry?,
        save: @escaping HolidayLabelSave,
        onError: @escaping (Error) -> Void
    ) -> HolidayLabelEditor {
        let id = holiday.id
        return HolidayLabelEditor.editor(
            holidayID: id,
            stored: holiday.label,
            in: registry,
            save: { label in
                try await save(id, label)
            },
            onError: { error in
                onError(error)
            }
        )
    }

    /// The model calls `SettingsView` hands the Alerts and Warm-up panes.
    static func thresholdsSave(_ model: AppModel) -> ThresholdsSave {
        { warning, critical, provider, window in
            try await model.setThresholds(
                warning: warning,
                critical: critical,
                provider: provider,
                window: window
            )
        }
    }

    static func cursorSpendSave(_ model: AppModel) -> CursorSpendSave {
        { warning, critical in
            try await model.setCursorSpend(warning: warning, critical: critical)
        }
    }

    static func holidayLabelSave(_ model: AppModel) -> HolidayLabelSave {
        { id, label in
            try await model.setHolidayLabel(id: id, label)
        }
    }
}
