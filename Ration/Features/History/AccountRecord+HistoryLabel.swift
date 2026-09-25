import Foundation

extension AccountRecord {
    /// Label for History-window surfaces, which keep showing paused accounts
    /// (their recorded usage is real data). The popover hides them instead.
    var historyLabel: String { historyLabel(locale: .current) }

    /// The user's own label is never translated; only the paused suffix is.
    func historyLabel(locale: Locale) -> String {
        guard isPaused else { return label }
        return LocalizedStringResource.historyLabelPaused(label).string(in: locale)
    }
}
