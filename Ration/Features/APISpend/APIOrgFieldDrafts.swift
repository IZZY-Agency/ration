import Foundation

/// The org pane's name and budget fields. They save on Return, when the field
/// loses focus, and when the pane closes (on Return alone, typing a budget
/// and clicking away saved nothing) — never per keystroke: "1" on the way to
/// "100" would set a $1 budget and could fire an alert.
@MainActor
final class APIOrgFieldDrafts: ObservableObject {
    @Published var label: String
    @Published var budget: String
    private var savedLabel: String
    private var savedBudgetCents: Int?
    private let locale: Locale
    private let onRename: (String) -> Void
    private let onBudget: (Int?) -> Void

    init(label: String, budgetCents: Int?, locale: Locale = .current,
         onRename: @escaping (String) -> Void, onBudget: @escaping (Int?) -> Void) {
        self.label = label
        self.budget = APIBudgetInput.text(forCents: budgetCents, locale: locale)
        self.savedLabel = label
        self.savedBudgetCents = budgetCents
        self.locale = locale
        self.onRename = onRename
        self.onBudget = onBudget
    }

    /// A real, non-empty change only (the model ignores an empty name).
    func commitLabel() {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != savedLabel else { return }
        savedLabel = trimmed
        onRename(trimmed)
    }

    /// Unreadable text saves nothing (the field shows why); empty clears it.
    func commitBudget() {
        guard case .success(let cents) = APIBudgetInput.cents(from: budget, locale: locale),
              cents != savedBudgetCents else { return }
        savedBudgetCents = cents
        onBudget(cents)
    }

    func commitAll() {
        commitLabel()
        commitBudget()
    }
}
