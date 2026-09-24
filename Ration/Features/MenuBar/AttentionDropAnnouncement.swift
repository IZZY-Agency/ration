import AppKit

/// Whether the attention drop should speak up.
///
/// The panel never takes focus (it must not steal the frontmost app's
/// keystrokes), so VoiceOver would never land on it by itself — it has to be
/// ANNOUNCED. But the drop re-derives on every refresh tick and publish, and
/// announcing each of those would repeat the same sentence every minute.
/// So it speaks only when it shows something new: when it appears, or when a
/// row that was not on it arrives. Rows leaving (a dismissal) and a row
/// escalating in place (the tier is not part of a row's identity) are not
/// news.
enum AttentionDropAnnouncement {
    /// - Parameters:
    ///   - rows: what the drop shows now; empty when it is closed.
    ///   - previouslySeen: the row ids it showed at the previous evaluation.
    /// - Returns: the sentence to announce, if any, and the ids to remember
    ///   for the next evaluation (empty once the drop closes, so its next
    ///   appearance speaks again).
    static func evaluate(
        rows: [AttentionRow],
        previouslySeen: Set<AttentionRow.ID>
    ) -> (announcement: String?, seen: Set<AttentionRow.ID>) {
        let seen = Set(rows.map(\.id))
        guard !seen.subtracting(previouslySeen).isEmpty else { return (nil, seen) }
        return (AttentionDropView.headerAccessibilityLabel(rows: rows), seen)
    }

    /// Posts `text` as a high-priority VoiceOver announcement without moving
    /// focus anywhere.
    @MainActor
    static func post(_ text: String) {
        NSAccessibility.post(
            element: NSApp.mainWindow ?? NSApp as Any,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ]
        )
    }
}
