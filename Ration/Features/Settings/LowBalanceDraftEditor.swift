import Combine
import Foundation

/// The Low balance row's one field: dollar text → an optional threshold in
/// cents (empty is off). Registered with `PendingEditRegistry`, so a quit with
/// the field still focused, or its save in flight, saves it first.
///
/// One save at a time: text typed while a save runs is sent after it, so the
/// older value can never land last. Unreadable text is never sent; it shows
/// the stored value again.
@MainActor
final class LowBalanceDraftEditor: ObservableObject, PendingEditFlushing {
    typealias Save = (Int?) async throws -> Void

    @Published var text: String
    private(set) var stored: Int?
    private var drawn: String
    private var saveTask: Task<Void, Never>?
    /// The latest save's number: only it clears `saveTask` or redraws.
    private var saveToken = 0
    private let save: Save
    private let onError: (Error) -> Void
    private let locale: Locale

    init(stored: Int?, locale: Locale = .current, save: @escaping Save, onError: @escaping (Error) -> Void) {
        self.stored = stored
        self.locale = locale
        self.save = save
        self.onError = onError
        let text = APIBudgetInput.text(forCents: stored, locale: locale)
        self.text = text
        self.drawn = text
    }

    /// The live editor for `provider`'s row, or a new one, registered.
    static func editor(
        provider: Provider,
        stored: Int?,
        in registry: PendingEditRegistry?,
        save: @escaping Save,
        onError: @escaping (Error) -> Void
    ) -> LowBalanceDraftEditor {
        let make = { LowBalanceDraftEditor(stored: stored, save: save, onError: onError) }
        guard let registry else { return make() }
        return registry.editor(forKey: "lowBalance.\(provider.rawValue)", make: make)
    }

    var hasPendingEdit: Bool { draft != nil || saveTask != nil }

    /// The typed value when it differs from what is stored, else nil.
    /// `.some(nil)` is "turn it off".
    private var draft: Int?? {
        guard text != drawn, case .success(let cents) = APIBudgetInput.cents(from: text, locale: locale),
              cents != stored else { return nil }
        return .some(cents)
    }

    /// Commits the field now (focus left it, Return, the pane closed).
    func submit() {
        guard let value = draft else {
            if saveTask == nil { draw(stored) }
            return
        }
        drawn = text
        saveToken += 1
        let token = saveToken
        let previous = saveTask
        saveTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            do {
                try await self.save(value)
                self.stored = value
            } catch {
                self.onError(error)
                if self.saveToken == token { self.draw(self.stored) }
            }
            if self.saveToken == token { self.saveTask = nil }
        }
    }

    func flushPendingEdit() async {
        submit()
        while let task = saveTask {
            await task.value
        }
    }

    /// The store published `cents`; drawn unless a save is running or the
    /// user is mid-edit.
    func storeDidChange(_ cents: Int?) {
        stored = cents
        guard saveTask == nil, text == drawn else { return }
        draw(cents)
    }

    private func draw(_ cents: Int?) {
        let text = APIBudgetInput.text(forCents: cents, locale: locale)
        self.text = text
        drawn = text
    }
}
