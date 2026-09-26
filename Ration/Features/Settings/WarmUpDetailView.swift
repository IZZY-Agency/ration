import SwiftUI

/// The "Warm-up" Settings pane: the weekly quiet-hours matrix + holiday ranges.
///
/// `AppSettings` publishes only AFTER a successful save, so no editor here may
/// read the published value, mutate it, and write the whole thing back — two
/// quick edits would both start from the same stale value and the second would
/// discard the first. Two different strategies avoid that:
///
/// * The grid writes through `QuietHoursAutosave`, which owns the draft and a
///   revision that advance together and saves after a debounce. The draft is
///   only considered saved once the save carrying the CURRENT revision
///   succeeds, so a failed or superseded save leaves it dirty (and retryable
///   on disappear, or on quit) rather than silently dropping edits.
/// * Holidays use atomic, FIELD-SPECIFIC id-addressed deltas on `AppSettings`
///   (label / start / end), which compose inside the serialized mutation.
///   Labels commit on blur (through `HolidayLabelEditor`, which a quit also
///   flushes) so per-keystroke writes never race; clamping lives in
///   `AppSettings`, on current data.
struct WarmUpDetailView: View {
    @ObservedObject var settings: AppSettings
    let autoStartEnabledCount: Int
    let onSetQuietHours: ([Int]) async throws -> Void
    let onAddHoliday: (HolidayRange) async throws -> Void
    let onSetHolidayLabel: (UUID, String) async throws -> Void
    let onSetHolidayStart: (UUID, LocalDate) async throws -> Void
    let onSetHolidayEnd: (UUID, LocalDate) async throws -> Void
    let onRemoveHoliday: (UUID) async throws -> Void
    let onError: (Error) -> Void
    var calendar: Calendar = .autoupdatingCurrent
    /// Where each holiday's label editor registers, so a quit saves a label
    /// that still has focus.
    private let pendingEdits: PendingEditRegistry?

    /// One per app while it has work (see `QuietHoursAutosave.editor`), so
    /// the save closure it keeps is the first one passed in. `SettingsView`'s
    /// closure only reaches the model, which never changes.
    @StateObject private var quietHours: QuietHoursAutosave

    init(
        settings: AppSettings,
        autoStartEnabledCount: Int,
        pendingEdits: PendingEditRegistry? = nil,
        onSetQuietHours: @escaping ([Int]) async throws -> Void,
        onAddHoliday: @escaping (HolidayRange) async throws -> Void,
        onSetHolidayLabel: @escaping (UUID, String) async throws -> Void,
        onSetHolidayStart: @escaping (UUID, LocalDate) async throws -> Void,
        onSetHolidayEnd: @escaping (UUID, LocalDate) async throws -> Void,
        onRemoveHoliday: @escaping (UUID) async throws -> Void,
        onError: @escaping (Error) -> Void,
        calendar: Calendar = .autoupdatingCurrent
    ) {
        _settings = ObservedObject(wrappedValue: settings)
        self.autoStartEnabledCount = autoStartEnabledCount
        self.onSetQuietHours = onSetQuietHours
        self.onAddHoliday = onAddHoliday
        self.onSetHolidayLabel = onSetHolidayLabel
        self.onSetHolidayStart = onSetHolidayStart
        self.onSetHolidayEnd = onSetHolidayEnd
        self.onRemoveHoliday = onRemoveHoliday
        self.onError = onError
        self.calendar = calendar
        self.pendingEdits = pendingEdits
        _quietHours = StateObject(
            wrappedValue: QuietHoursAutosave.editor(
                stored: settings.quietHours,
                in: pendingEdits,
                save: { cells in
                    try await onSetQuietHours(cells)
                },
                onError: { error in
                    onError(error)
                }
            )
        )
    }

    /// What the schedule currently governs. Quiet hours stopped being
    /// warm-up-only in 0.28.0, so "no auto-start account" no longer means "no
    /// effect" — the drop is governed too. See `QuietHoursScope`.
    private var scope: QuietHoursScope {
        QuietHoursScope.current(
            settings: settings.data,
            autoStartEnabledCount: autoStartEnabledCount,
            channelKeys: AlertsGridModel.allChannelKeys
        )
    }

    /// The grid writes through this. Programmatic store→draft sync
    /// (`storeDidChange`) bypasses it, so opening the pane never schedules a
    /// save.
    private var gridSelection: Binding<Set<Int>> {
        let quietHours = quietHours
        return Binding(
            get: { quietHours.draft },
            set: { newValue in
                quietHours.select(newValue)
            }
        )
    }

    var body: some View {
        Form {
            Section(SettingsSectionTitle.quietHours) {
                QuietHoursGrid(selection: gridSelection, calendar: calendar)
                Text("Selected hours never trigger a warm-up, and the menu-bar drop stays hidden until they pass. Notifications still arrive. Click a day or an hour to select the whole column or row.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.creamDim)
                if scope.governsNothing {
                    Text("No account has auto-start enabled and no alert delivers to the drop, so quiet hours have no effect yet.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.warn)
                }
            }

            Section(SettingsSectionTitle.holidays) {
                ForEach(settings.holidays) { holiday in
                    HolidayRow(
                        holiday: holiday,
                        calendar: calendar,
                        pendingEdits: pendingEdits,
                        saveLabel: onSetHolidayLabel,
                        onError: onError,
                        onSetStart: { start in perform { try await onSetHolidayStart(holiday.id, start) } },
                        onSetEnd: { end in perform { try await onSetHolidayEnd(holiday.id, end) } },
                        onRemove: { perform { try await onRemoveHoliday(holiday.id) } }
                    )
                    .id(holiday.id)
                }
                Button {
                    let today = LocalDate(.now, calendar: calendar)
                    perform {
                        try await onAddHoliday(HolidayRange(start: today, end: today, label: ""))
                    }
                } label: {
                    Label("Add range", systemImage: "plus")
                }
                if settings.holidays.isEmpty {
                    Text("Warm-up never fires on these dates, and the menu-bar drop stays hidden.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.creamDim)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.ink)
        .task { quietHours.storeDidChange(settings.quietHours) }
        .onChange(of: settings.quietHours) { _, newValue in
            quietHours.storeDidChange(newValue)
        }
        // Starts the save; a quit that outruns it is covered by the
        // `PendingEditRegistry` the model registered with.
        .onDisappear { quietHours.flush() }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await operation()
            } catch {
                onError(error)
            }
        }
    }
}

/// One holiday range. Its label lives in a `HolidayLabelEditor`, which
/// commits on blur/submit so a per-keystroke write can never race the settings
/// store, and which a quit flushes. Each editor calls a FIELD-specific delta,
/// so a label commit and a date change compose in the store instead of
/// overwriting each other's field.
private struct HolidayRow: View {
    let holiday: HolidayRange
    let calendar: Calendar
    let onSetStart: (LocalDate) -> Void
    let onSetEnd: (LocalDate) -> Void
    let onRemove: () -> Void

    @StateObject private var labelEditor: HolidayLabelEditor
    @FocusState private var labelFocused: Bool

    init(
        holiday: HolidayRange,
        calendar: Calendar,
        pendingEdits: PendingEditRegistry?,
        saveLabel: @escaping (UUID, String) async throws -> Void,
        onError: @escaping (Error) -> Void,
        onSetStart: @escaping (LocalDate) -> Void,
        onSetEnd: @escaping (LocalDate) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.holiday = holiday
        self.calendar = calendar
        self.onSetStart = onSetStart
        self.onSetEnd = onSetEnd
        self.onRemove = onRemove
        _labelEditor = StateObject(
            wrappedValue: SettingsEditors.holidayLabel(
                holiday,
                in: pendingEdits,
                save: saveLabel,
                onError: onError
            )
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Label", text: $labelEditor.text)
                .frame(maxWidth: 140)
                .focused($labelFocused)
                .onSubmit {
                    labelFocused = false
                    labelEditor.commit()
                }
                .onChange(of: labelFocused) { _, focused in
                    labelEditor.focusChanged(focused)
                }
            DatePicker("", selection: dateBinding(isStart: true), displayedComponents: .date)
                .labelsHidden()
            Text(verbatim: "–").foregroundStyle(Theme.creamDim)
            DatePicker("", selection: dateBinding(isStart: false), displayedComponents: .date)
                .labelsHidden()
            Spacer(minLength: 4)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.crit)
            .accessibilityLabel(removeLabel)
        }
        // A reopened pane may get an editor that outlived the last one, and
        // that may still hold an edit whose save failed: show the error again.
        .task {
            labelEditor.storeDidChange(holiday.label)
            labelEditor.paneAppeared()
        }
        .onChange(of: holiday.label) { _, newValue in
            // Adopted only while the user has nothing uncommitted, so a store
            // republish (e.g. from another edit) doesn't yank the caret.
            labelEditor.storeDidChange(newValue)
        }
        // Starts the save; a quit that outruns it is covered by the
        // `PendingEditRegistry` the editor registered with.
        .onDisappear { labelEditor.commit() }
    }

    /// "Remove Winter break", or "Remove range" for an unnamed one. The
    /// label is the user's own text.
    private var removeLabel: Text {
        if holiday.label.isEmpty {
            return Text("Remove range")
        }
        return Text("Remove \(holiday.label)")
    }

    /// Bridges `LocalDate` <-> `Date` for `DatePicker`. Clamping lives in the
    /// store (against current data); the view just reports the picked day.
    private func dateBinding(isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                let value = isStart ? holiday.start : holiday.end
                return value.startOfDay(in: calendar) ?? .now
            },
            set: { newValue in
                let local = LocalDate(newValue, calendar: calendar)
                if isStart { onSetStart(local) } else { onSetEnd(local) }
            }
        )
    }
}
