import Foundation

/// Pure formatter turning an `AlertEvent` into user-facing notification copy
/// and a stable identifier. No I/O, no framework dependency — safe to unit test.
enum AlertMessage {
    /// Builds notification copy. When `redacted` is true (the user's
    /// notification privacy mode), the account label and exact
    /// percentage/window are omitted — a label can be an email address,
    /// employer, or client name, and both it and the precise usage state would
    /// otherwise appear in a lock-screen preview. The generic copy still tells
    /// the user Ration needs attention; opening the app shows which
    /// account and why.
    static func text(
        for event: AlertEvent,
        accountLabel: String,
        redacted: Bool = false
    ) -> (title: String, body: String) {
        guard !redacted else {
            return redactedText(for: event)
        }
        switch event {
        case .threshold(let kind, _, let percent, let label):
            return (
                "\(accountLabel): \(shortLabel(for: kind, apiLabel: label)) limit at \(percent)%",
                "You've used \(percent)% of the \(longLabel(for: kind, apiLabel: label)) limit for \(accountLabel)."
            )
        case .reset(let kind, let label):
            return (
                "\(accountLabel): \(shortLabel(for: kind, apiLabel: label)) limit reset",
                "Fresh \(longLabel(for: kind, apiLabel: label)) capacity is available for \(accountLabel)."
            )
        case .reauthRequired:
            return (
                "\(accountLabel): sign in again",
                "Ration can't read \(accountLabel)'s limits until you sign in again."
            )
        case .rateLimited:
            return (
                "\(accountLabel): rate-limited",
                "The provider is rate-limiting usage checks for \(accountLabel)."
            )
        case .spendThreshold(_, let thresholdCents, let spentCents):
            let spent = AlertMessage.dollars(spentCents)
            let limit = AlertMessage.dollars(thresholdCents)
            // `AlertPolicy` fires this on `>=`, so landing exactly ON the
            // threshold is a real case — and "past $50" would be wrong for it.
            let verb = spentCents > thresholdCents ? "past" : "reached"
            return (
                "\(accountLabel): Cursor spend \(verb) \(limit)",
                "\(accountLabel) has spent \(spent) this billing cycle, \(verb) your \(limit) alert."
            )
        }
    }

    /// Label-free, percentage-free copy for privacy mode. Carries the event
    /// category (so the notification is still actionable) but nothing that
    /// identifies the account or its exact usage.
    private static func redactedText(for event: AlertEvent) -> (title: String, body: String) {
        switch event {
        case .threshold:
            return ("Ration", "An account is nearing a usage limit.")
        case .reset:
            return ("Ration", "An account's limit has reset.")
        case .reauthRequired:
            return ("Ration", "An account needs you to sign in again.")
        case .rateLimited:
            return ("Ration", "An account is being rate-limited.")
        case .spendThreshold:
            return ("Ration", "An account is nearing a spend limit.")
        }
    }

    static func id(for event: AlertEvent, accountID: UUID) -> String {
        let base = accountID.uuidString
        switch event {
        case .threshold(let kind, let tier, _, _):
            return "\(base).threshold.\(kind.rawValue).\(tier.token)"
        case .reset(let kind, _):
            return "\(base).reset.\(kind.rawValue)"
        case .reauthRequired:
            return "\(base).reauth"
        case .rateLimited:
            return "\(base).rateLimited"
        case .spendThreshold(let tier, _, _):
            return "\(base).spend.\(tier.token)"
        }
    }

    /// Short wording used in notification titles, e.g. "5h". For
    /// `.modelWeekly`, prefers the window's API-provided label (e.g. "Fable")
    /// over the generic static wording; falls back to "Fable" if the API
    /// label is absent. Other kinds ignore `apiLabel` (it is always nil for
    /// them) and keep their static wording.
    private static func shortLabel(for kind: UsageWindowKind, apiLabel: String?) -> String {
        if kind == .modelWeekly { return apiLabel ?? "Fable" }
        return kind.shortLabel
    }

    /// Longer wording used in notification bodies, e.g. "5-hour". Same
    /// API-label preference as `shortLabel(for:apiLabel:)`.
    private static func longLabel(for kind: UsageWindowKind, apiLabel: String?) -> String {
        if kind == .modelWeekly { return apiLabel ?? "Fable" }
        return kind.longLabel
    }

    /// Formats cents as a USD amount in `locale`'s conventions. Drops fraction
    /// digits when the amount is a whole number of dollars, so round configured
    /// thresholds read as "$50" rather than "$50.00" in copy.
    ///
    /// The rendering is LOCALIZED, not fixed: the same 5_000 is "$50" under
    /// `en_US`, "US$50" under `en_FR`, and "50 $US" under `fr_FR` — the
    /// currency is always USD (Cursor bills in dollars), but the symbol form,
    /// placement, and decimal separator follow the reader's locale. Callers
    /// must not pattern-match the result.
    ///
    /// `locale` is injectable so the formatting can be pinned in tests; it
    /// defaults to the reader's locale for all production copy.
    static func dollars(_ cents: Int, locale: Locale = .autoupdatingCurrent) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.locale = locale
        formatter.maximumFractionDigits = cents % 100 == 0 ? 0 : 2
        return formatter.string(from: NSNumber(value: Double(cents) / 100))
            ?? "$\(Double(cents) / 100)"
    }
}

private extension UsageWindowKind {
    /// Short wording used in notification titles, e.g. "5h".
    var shortLabel: String {
        switch self {
        case .fiveHour: "5h"
        case .weekly: "weekly"
        case .modelWeekly: "model"
        }
    }

    /// Longer wording used in notification bodies, e.g. "5-hour".
    var longLabel: String {
        switch self {
        case .fiveHour: "5-hour"
        case .weekly: "weekly"
        case .modelWeekly: "model weekly"
        }
    }
}

private extension AlertTier {
    /// Stable, human-readable token used to build notification identifiers.
    var token: String {
        switch self {
        case .warning: "warning"
        case .critical: "critical"
        }
    }
}
