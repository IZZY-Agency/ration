import Foundation

extension AccountRecord {
    /// Label for History-window surfaces, which keep showing paused accounts
    /// (their recorded usage is real data). The popover hides them instead.
    var historyLabel: String {
        isPaused ? "\(label) — PAUSED" : label
    }
}
