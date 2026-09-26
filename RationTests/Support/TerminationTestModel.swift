import Foundation
import WebKit
@testable import Ration

/// A real `AppModel` over temporary files, with one account on disk and no
/// WebKit, network or power observers — for driving the quit path
/// (`requiresTerminationPreparation` / `prepareForTermination`).
@MainActor
struct TerminationTestModel {
    let directory: URL
    let model: AppModel
    let accountStore: AccountStore
    let appSettings: AppSettings
    let account: AccountRecord

    static func make(
        pendingEdits: PendingEditRegistry = PendingEditRegistry()
    ) async throws -> TerminationTestModel {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let accountStore = AccountStore(fileURL: directory.appending(path: "accounts.json"))
        let appSettings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        try await accountStore.load()
        try await appSettings.load()
        let account = AccountRecord(
            id: UUID(),
            provider: .claude,
            label: "Work",
            webProfileID: UUID(),
            displayOrder: 0,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
        try await accountStore.add(account)
        let model = AppModel(
            accountStore: accountStore,
            snapshotStore: UsageSnapshotStore(fileURL: directory.appending(path: "snapshots.json")),
            pendingProfileDeletionStore: PendingProfileDeletionStore(
                fileURL: directory.appending(path: "pending-profile-deletions.json")
            ),
            historyStore: UsageHistoryStore(
                rootDirectory: directory.appending(path: "history", directoryHint: .isDirectory)
            ),
            appSettings: appSettings,
            alertStateStore: AlertStateStore(fileURL: directory.appending(path: "alert-state.json")),
            profileManager: TerminationWebProfileManagerStub(),
            adapterRegistry: ProviderAdapterRegistry(adapters: []),
            now: { Date(timeIntervalSince1970: 1_000) },
            systemPowerObserver: NoopSystemPowerObserver(),
            pendingEdits: pendingEdits
        )
        return TerminationTestModel(
            directory: directory,
            model: model,
            accountStore: accountStore,
            appSettings: appSettings,
            account: account
        )
    }

    /// The label as a relaunched app reads it from disk.
    func labelOnDisk() async throws -> String? {
        let store = AccountStore(fileURL: directory.appending(path: "accounts.json"))
        try await store.load()
        return store.accounts.first { $0.id == account.id }?.label
    }

    /// The quiet hours as a relaunched app reads them from disk.
    func quietHoursOnDisk() async throws -> [Int] {
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        try await settings.load()
        return settings.quietHours
    }

    /// The label field's model as `SettingsView` builds it for this account.
    func labelAutosave() -> LabelAutosave {
        let model = model
        let id = account.id
        return LabelAutosave.editor(
            accountID: id,
            stored: account.label,
            in: model.pendingEdits,
            save: { label in
                try await model.renameAccount(id: id, label: label)
            },
            onError: { _ in }
        )
    }

    /// The quiet-hours grid's model as `SettingsView` builds it.
    func quietHoursAutosave() -> QuietHoursAutosave {
        let model = model
        return QuietHoursAutosave.editor(
            stored: model.settings.quietHours,
            in: model.pendingEdits,
            save: { cells in
                try await model.setQuietHours(cells)
            },
            onError: { _ in }
        )
    }

    /// The settings as a relaunched app reads them from disk.
    func settingsOnDisk() async throws -> AppSettings {
        let settings = AppSettings(fileURL: directory.appending(path: "app-settings.json"))
        try await settings.load()
        return settings
    }

    // The editors below come from the SAME factories the panes use
    // (`SettingsEditors`), bound to the model by the SAME closures
    // `SettingsView` passes, so a broken key, registry or binding fails here.

    /// A percent row's editor as `AlertsDetailView` builds it.
    func thresholdEditor(
        provider: Provider,
        window: UsageWindowKind
    ) -> ThresholdDraftEditor<ThresholdPair, Int> {
        SettingsEditors.thresholdRow(
            AlertsGridRow(provider: provider, window: window),
            stored: model.settings.data.thresholds(provider: provider, window: window),
            in: model.pendingEdits,
            save: SettingsEditors.thresholdsSave(model),
            onError: { _ in }
        )
    }

    /// Cursor's spend editor as `AlertsDetailView` builds it.
    func cursorSpendEditor() -> ThresholdDraftEditor<SpendThresholds, Int?> {
        SettingsEditors.cursorSpend(
            stored: model.settings.cursorSpend,
            in: model.pendingEdits,
            save: SettingsEditors.cursorSpendSave(model),
            onError: { _ in }
        )
    }

    /// A holiday's label editor as `WarmUpDetailView` builds it. `save`
    /// defaults to the model binding `SettingsView` passes.
    func holidayLabelEditor(
        _ holiday: HolidayRange,
        save: SettingsEditors.HolidayLabelSave? = nil,
        onError: @escaping (Error) -> Void = { _ in }
    ) -> HolidayLabelEditor {
        let bound = SettingsEditors.holidayLabelSave(model)
        return SettingsEditors.holidayLabel(
            holiday,
            in: model.pendingEdits,
            save: save ?? bound,
            onError: onError
        )
    }

    nonisolated func removeFiles() {
        try? FileManager.default.removeItem(at: directory)
    }
}

@MainActor
private final class TerminationWebProfileManagerStub: WebProfileManaging {
    func makeWebView(profileID: UUID) -> WKWebView {
        WKWebView(frame: .zero)
    }

    func removeProfile(profileID: UUID) async throws {}
}
