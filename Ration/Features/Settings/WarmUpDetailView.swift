import SwiftUI

/// The "Warm-up" Settings pane: the weekly quiet-hours matrix + holiday ranges.
///
/// `AppSettings` publishes only AFTER a successful save, so no editor here may
/// read the published value, mutate it, and write the whole thing back — two
/// quick edits would both start from the same stale value and the second would
/// discard the first. Two different strategies avoid that:
///
/// * The grid writes through a binding whose setter updates the local `draft`
///   AND bumps `draftRevision` synchronously, then schedules a debounced save.
///   The draft is only considered saved once the save carrying the CURRENT
///   revision succeeds, so a failed or superseded save leaves it dirty (and
///   retryable on disappear) rather than silently dropping edits. Because the
///   revision advances in the same setter call as the value, no save can slip
///   in and mark a newer draft clean.
/// * Holidays use atomic, FIELD-SPECIFIC id-addressed deltas on `AppSettings`
///   (label / start / end), which compose inside the serialized mutation.
///   Labels commit on blur so per-keystroke writes never race; clamping lives
///   in `AppSettings`, on current data.
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

    @State private var draft: Set<Int> = []
    @State private var draftRevision = 0
    @State private var savedRevision = 0
    @State private var saveTask: Task<Void, Never>?

    private static let debounce: Duration = .milliseconds(400)

    private var isDirty: Bool { draftRevision != savedRevision }

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

    /// The grid writes through this: value + revision advance atomically, so a
    /// concurrent save can never observe a bumped revision without the matching
    /// value (or vice-versa). Programmatic store→draft sync (`syncDraftIfClean`)
    /// deliberately bypasses this, so opening the pane never schedules a save.
    private var gridSelection: Binding<Set<Int>> {
        Binding(
            get: { draft },
            set: { newValue in
                guard newValue != draft else { return }
                draft = newValue
                draftRevision += 1
                scheduleSave()
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
                        onSetLabel: { label in perform { try await onSetHolidayLabel(holiday.id, label) } },
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
        .task { syncDraftIfClean() }
        .onChange(of: settings.quietHours) { _, _ in syncDraftIfClean() }
        .onDisappear { flush() }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled else { return }
            await save(revision: draftRevision, value: draft)
        }
    }

    /// Persists `value` and marks the draft clean ONLY if `revision` is still
    /// the newest — a slow save that lands after a newer edit must not declare
    /// the newer edit saved.
    private func save(revision: Int, value: Set<Int>) async {
        do {
            try await onSetQuietHours(Array(value))
            if revision == draftRevision {
                savedRevision = revision
            }
        } catch {
            onError(error)
        }
    }

    /// Adopt the store's value as the baseline, but only while the user has no
    /// unsaved edit — never clobber a dirty draft. Bypasses `gridSelection`, so
    /// it neither bumps the revision nor schedules a (redundant) save.
    private func syncDraftIfClean() {
        guard !isDirty else { return }
        draft = Set(settings.quietHours)
    }

    /// Last chance to persist a pending edit when the pane goes away.
    private func flush() {
        saveTask?.cancel()
        guard isDirty else { return }
        let revision = draftRevision
        let value = draft
        Task { await save(revision: revision, value: value) }
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

/// One holiday range. Owns its label locally and commits on blur/submit so a
/// per-keystroke write can never race the settings store. Each editor calls a
/// FIELD-specific delta, so a label commit and a date change compose in the
/// store instead of overwriting each other's field.
private struct HolidayRow: View {
    let holiday: HolidayRange
    let calendar: Calendar
    let onSetLabel: (String) -> Void
    let onSetStart: (LocalDate) -> Void
    let onSetEnd: (LocalDate) -> Void
    let onRemove: () -> Void

    @State private var label: String
    @FocusState private var labelFocused: Bool

    init(
        holiday: HolidayRange,
        calendar: Calendar,
        onSetLabel: @escaping (String) -> Void,
        onSetStart: @escaping (LocalDate) -> Void,
        onSetEnd: @escaping (LocalDate) -> Void,
        onRemove: @escaping () -> Void
    ) {
        self.holiday = holiday
        self.calendar = calendar
        self.onSetLabel = onSetLabel
        self.onSetStart = onSetStart
        self.onSetEnd = onSetEnd
        self.onRemove = onRemove
        _label = State(initialValue: holiday.label)
    }

    var body: some View {
        HStack(spacing: 8) {
            TextField("Label", text: $label)
                .frame(maxWidth: 140)
                .focused($labelFocused)
                .onSubmit { labelFocused = false }
                .onChange(of: labelFocused) { _, focused in
                    if !focused { commitLabel() }
                }
            DatePicker("", selection: dateBinding(isStart: true), displayedComponents: .date)
                .labelsHidden()
            Text("–").foregroundStyle(Theme.creamDim)
            DatePicker("", selection: dateBinding(isStart: false), displayedComponents: .date)
                .labelsHidden()
            Spacer(minLength: 4)
            Button(action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.crit)
            .accessibilityLabel("Remove \(holiday.label.isEmpty ? "range" : holiday.label)")
        }
        .onChange(of: holiday.label) { _, newValue in
            // Re-sync the field only when the user isn't mid-edit, so a store
            // republish (e.g. from another edit) doesn't yank the caret.
            if !labelFocused, newValue != label { label = newValue }
        }
    }

    private func commitLabel() {
        guard label != holiday.label else { return }
        onSetLabel(label)
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
