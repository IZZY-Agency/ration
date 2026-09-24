import Foundation

/// Every surface's wording for a `SwitchAdvice`, in one
/// place so the header, the notification and the drop can never disagree on
/// the number or the target. Pure.
enum SwitchAdviceCopy {
    /// The target's remaining share of its binding limit, as a whole percent.
    static func percent(_ advice: SwitchAdvice) -> Int {
        let scaled: Double = advice.toHeadroom * 100
        return Int(scaled.rounded())
    }

    /// The popover header line, split so the view can colour the target
    /// differently: `lead` + `target` + `tail`, joined by spaces, is the
    /// line after the arrow.
    static func headerParts(_ advice: SwitchAdvice) -> (lead: String, target: String, tail: String) {
        let lead = "SWITCH \(advice.provider.displayName.uppercased()) TO"
        let tail = "· \(percent(advice))% OF \(bindingHeaderWord(advice.toBinding)) LEFT"
        return (lead, advice.toLabel, tail)
    }

    /// "→ SWITCH CLAUDE TO Personal · 85% OF WEEK LEFT"
    static func headerText(_ advice: SwitchAdvice) -> String {
        let parts = headerParts(advice)
        return "→ \(parts.lead) \(parts.target) \(parts.tail)"
    }

    /// "Switch Claude to Personal, 85 percent of the week left"
    static func spokenHeader(_ advice: SwitchAdvice) -> String {
        "Switch \(advice.provider.displayName) to \(advice.toLabel), \(percent(advice)) percent of \(bindingSpokenWords(advice.toBinding)) left"
    }

    /// The line appended to a Warn/Critical notification body. Redacted
    /// (privacy mode) names neither account nor any number.
    static func notificationLine(_ advice: SwitchAdvice, redacted: Bool) -> String {
        if redacted {
            return "Another \(advice.provider.displayName) account has more room."
        }
        return "Switch to \(advice.toLabel) — \(percent(advice))% of its \(bindingNotificationWords(advice.toBinding)) left."
    }

    /// The header line's accessibility identifier, per provider:
    /// "headerSwitchAdvice.claude" / "headerSwitchAdvice.chatGPT".
    static func headerIdentifier(_ advice: SwitchAdvice) -> String {
        "headerSwitchAdvice.\(advice.provider)"
    }

    /// Drawn after the from-account's name on a drop row: "→ Personal".
    static func dropSuffix(_ advice: SwitchAdvice) -> String {
        "→ \(advice.toLabel)"
    }

    /// Appended to the drop row's accessibility label: ", switch to Personal".
    static func dropSpokenSuffix(_ advice: SwitchAdvice) -> String {
        ", switch to \(advice.toLabel)"
    }

    private static func bindingHeaderWord(_ kind: UsageWindowKind) -> String {
        switch kind {
        case .weekly: "WEEK"
        case .fiveHour: "5 HOURS"
        case .modelWeekly: "FABLE"
        }
    }

    private static func bindingSpokenWords(_ kind: UsageWindowKind) -> String {
        switch kind {
        case .weekly: "the week"
        case .fiveHour: "the 5 hours"
        case .modelWeekly: "Fable"
        }
    }

    private static func bindingNotificationWords(_ kind: UsageWindowKind) -> String {
        switch kind {
        case .weekly: "week"
        case .fiveHour: "5 hours"
        case .modelWeekly: "Fable"
        }
    }
}
