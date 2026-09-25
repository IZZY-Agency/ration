import Foundation

/// Every surface's wording for a `SwitchAdvice`, in one
/// place so the header, the notification and the drop can never disagree on
/// the number or the target. Pure.
///
/// Every line is one catalog entry per binding window, resolved in `locale`
/// (the running language by default). The provider name and the account
/// label are placeholders, never translated; the header's capitals live in
/// the catalog, never applied at runtime to translated words.
enum SwitchAdviceCopy {
    /// The target's remaining share of its binding limit, as a whole percent.
    static func percent(_ advice: SwitchAdvice) -> Int {
        let scaled: Double = advice.toHeadroom * 100
        return Int(scaled.rounded())
    }

    /// The popover header line, split so the view can colour the target
    /// differently: `lead` + `target` + `tail`, joined by spaces, is the
    /// line after the arrow.
    ///
    /// The whole line is one catalog entry, so a language can put the target
    /// anywhere: the entry is resolved with a marker in the target's place and
    /// cut around it.
    static func headerParts(
        _ advice: SwitchAdvice,
        locale: Locale = .current
    ) -> (lead: String, target: String, tail: String) {
        let line: String = header(advice, target: String(targetMarker), locale: locale)
        let pieces: [Substring] = line.split(separator: targetMarker, maxSplits: 1, omittingEmptySubsequences: false)
        var lead: Substring = pieces.first ?? ""
        if lead.hasPrefix(arrow) {
            lead = lead.dropFirst(arrow.count)
        }
        let tail: Substring = pieces.count > 1 ? pieces[1] : ""
        return (
            lead.trimmingCharacters(in: .whitespaces),
            advice.toLabel,
            tail.trimmingCharacters(in: .whitespaces)
        )
    }

    /// "→ SWITCH CLAUDE TO Personal · 85% OF WEEK LEFT"
    static func headerText(_ advice: SwitchAdvice, locale: Locale = .current) -> String {
        header(advice, target: advice.toLabel, locale: locale)
    }

    /// "Switch Claude to Personal, 85 percent of the week left"
    static func spokenHeader(_ advice: SwitchAdvice, locale: Locale = .current) -> String {
        let provider: String = advice.provider.displayName
        let value: Int = percent(advice)
        let resource: LocalizedStringResource = switch advice.toBinding {
        case .weekly: .switchAdviceSpokenWeek(provider, advice.toLabel, percent: value)
        case .fiveHour: .switchAdviceSpokenFiveHours(provider, advice.toLabel, percent: value)
        case .modelWeekly: .switchAdviceSpokenFable(provider, advice.toLabel, percent: value)
        }
        return resource.string(in: locale)
    }

    /// The line appended to a Warn/Critical notification body. Redacted
    /// (privacy mode) names neither account nor any number.
    static func notificationLine(
        _ advice: SwitchAdvice,
        redacted: Bool,
        locale: Locale = .current
    ) -> String {
        if redacted {
            return LocalizedStringResource.switchAdviceNotificationRedacted(advice.provider.displayName)
                .string(in: locale)
        }
        let value: Int = percent(advice)
        let resource: LocalizedStringResource = switch advice.toBinding {
        case .weekly: .switchAdviceNotificationWeek(advice.toLabel, value)
        case .fiveHour: .switchAdviceNotificationFiveHours(advice.toLabel, value)
        case .modelWeekly: .switchAdviceNotificationFable(advice.toLabel, value)
        }
        return resource.string(in: locale)
    }

    /// The header line's accessibility identifier, per provider:
    /// "headerSwitchAdvice.claude" / "headerSwitchAdvice.chatGPT".
    static func headerIdentifier(_ advice: SwitchAdvice) -> String {
        "headerSwitchAdvice.\(advice.provider)"
    }

    /// Drawn after the from-account's name on a drop row: "→ Personal".
    /// An arrow and a label: nothing to translate.
    static func dropSuffix(_ advice: SwitchAdvice) -> String {
        "→ \(advice.toLabel)"
    }

    /// Appended to the drop row's accessibility label: ", switch to Personal".
    static func dropSpokenSuffix(_ advice: SwitchAdvice, locale: Locale = .current) -> String {
        LocalizedStringResource.switchAdviceDropSpokenSuffix(advice.toLabel).string(in: locale)
    }

    private static let arrow = "→"
    /// Stands in for the target while the header is cut into parts. A
    /// private-use character: no label or translation contains it.
    private static let targetMarker: Character = "\u{E000}"

    /// The full header line with `target` in the account's place. The
    /// provider name is a brand in Latin letters, so its capitals are
    /// locale-independent.
    private static func header(_ advice: SwitchAdvice, target: String, locale: Locale) -> String {
        let provider: String = advice.provider.displayName.uppercased()
        let value: Int = percent(advice)
        let resource: LocalizedStringResource = switch advice.toBinding {
        case .weekly: .switchAdviceHeaderWeek(provider, target, value)
        case .fiveHour: .switchAdviceHeaderFiveHours(provider, target, value)
        case .modelWeekly: .switchAdviceHeaderFable(provider, target, value)
        }
        return resource.string(in: locale)
    }
}
