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
    ///
    /// `advice` is the switch advice whose `from` is this event's account,
    /// matched by the caller at composition time. It adds one line to the
    /// body of a limit crossing (`.threshold`, Warn or Critical) and is
    /// ignored for every other event; privacy mode gets the label- and
    /// number-free line.
    ///
    /// The copy is resolved in `locale` — the running language by default.
    /// `AppModel` calls this when it posts the notification, so the text is
    /// always in the language the app is running in at delivery.
    static func text(
        for event: AlertEvent,
        accountLabel: String,
        redacted: Bool = false,
        advice: SwitchAdvice? = nil,
        locale: Locale = .current
    ) -> (title: String, body: String) {
        let base: (title: String, body: String) = redacted
            ? redactedText(for: event, locale: locale)
            : plainText(for: event, accountLabel: accountLabel, locale: locale)
        guard case .threshold = event, let advice else { return base }
        let line: String = SwitchAdviceCopy.notificationLine(advice, redacted: redacted, locale: locale)
        return (base.title, base.body + "\n" + line)
    }

    private static func plainText(
        for event: AlertEvent,
        accountLabel: String,
        locale: Locale
    ) -> (title: String, body: String) {
        let copy: (title: LocalizedStringResource, body: LocalizedStringResource)
        switch event {
        case .threshold(let kind, _, let percent, let label):
            copy = thresholdCopy(kind: kind, modelLabel: label ?? "Fable", percent: percent, account: accountLabel)
        case .reset(let kind, let label):
            copy = resetCopy(kind: kind, modelLabel: label ?? "Fable", account: accountLabel)
        case .reauthRequired:
            copy = (.alertReauthTitle(accountLabel), .alertReauthBody(accountLabel))
        case .rateLimited:
            copy = (.alertRateLimitedTitle(accountLabel), .alertRateLimitedBody(accountLabel))
        case .spendThreshold(_, let thresholdCents, let spentCents):
            let spent = AlertMessage.dollars(spentCents, locale: locale)
            let limit = AlertMessage.dollars(thresholdCents, locale: locale)
            // `AlertPolicy` fires this on `>=`, so landing exactly ON the
            // threshold is a real case — and "past $50" would be wrong for it.
            copy = spentCents > thresholdCents
                ? (.alertSpendTitlePast(accountLabel, limit), .alertSpendBodyPast(accountLabel, spent, limit))
                : (.alertSpendTitleReached(accountLabel, limit), .alertSpendBodyReached(accountLabel, spent, limit))
        case .resetCreditAvailable(let credit, let expiringSoon):
            let expiry = Self.expiryText(credit.expiresAt, locale: locale)
            // The real rule is on `count`, not on where the count came
            // from: whenever `count > 1` the body says how many, generically
            // — dropping any title. This covers a COLLAPSED multi-credit
            // event (`ResetCreditPolicy.evaluate`'s merge, when several
            // credits fire together — those never carry a single title to
            // name in the first place) AND a single provider-reported credit
            // whose own `count` is > 1 (e.g. Claude's `resets_left`) that
            // happens to carry a title — naming the title there would
            // contradict the title line just above it, which already says
            // "N resets available". Only an untitled OR titled credit with
            // `count == 1` uses the singular, title-aware wording.
            if credit.count > 1 {
                copy = (
                    expiringSoon
                        ? .alertResetCreditAvailableTitleMultipleExpiringSoon(accountLabel, count: credit.count)
                        : .alertResetCreditAvailableTitleMultiple(accountLabel, count: credit.count),
                    .alertResetCreditAvailableBodyMultiple(count: credit.count, accountLabel, expiry)
                )
            } else {
                let body: LocalizedStringResource
                if let title = credit.title {
                    body = .alertResetCreditAvailableBodyTitled(title, accountLabel, expiry)
                } else {
                    body = .alertResetCreditAvailableBodyUntitled(accountLabel, expiry)
                }
                copy = (
                    expiringSoon
                        ? .alertResetCreditAvailableTitleSingleExpiringSoon(accountLabel)
                        : .alertResetCreditAvailableTitleSingle(accountLabel),
                    body
                )
            }
        case .resetCreditExpiring(let credit):
            let expiry = Self.expiryText(credit.expiresAt, locale: locale)
            // See `.resetCreditAvailable` above: the plural, title-less body
            // applies whenever `count > 1`, titled or not.
            let body: LocalizedStringResource
            if credit.count > 1 {
                body = .alertResetCreditExpiringBodyMultiple(count: credit.count, accountLabel, expiry)
            } else if let title = credit.title {
                body = .alertResetCreditExpiringBodyTitled(title, accountLabel, expiry)
            } else {
                body = .alertResetCreditExpiringBodyUntitled(accountLabel, expiry)
            }
            copy = (.alertResetCreditExpiringTitle(accountLabel), body)
        }
        return (copy.title.string(in: locale), copy.body.string(in: locale))
    }

    /// A limit crossing, per window. For `.modelWeekly` the window's
    /// API-provided label (e.g. "Fable") names it; the others have fixed
    /// wording.
    private static func thresholdCopy(
        kind: UsageWindowKind,
        modelLabel: String,
        percent: Int,
        account: String
    ) -> (title: LocalizedStringResource, body: LocalizedStringResource) {
        switch kind {
        case .fiveHour:
            (.alertThresholdTitleFiveHour(account, percent), .alertThresholdBodyFiveHour(percent, account))
        case .weekly:
            (.alertThresholdTitleWeekly(account, percent), .alertThresholdBodyWeekly(percent, account))
        case .modelWeekly:
            (.alertThresholdTitleModel(account, modelLabel, percent), .alertThresholdBodyModel(percent, modelLabel, account))
        }
    }

    /// A window reset, with the same API-label preference as `thresholdCopy`.
    private static func resetCopy(
        kind: UsageWindowKind,
        modelLabel: String,
        account: String
    ) -> (title: LocalizedStringResource, body: LocalizedStringResource) {
        switch kind {
        case .fiveHour: (.alertResetTitleFiveHour(account), .alertResetBodyFiveHour(account))
        case .weekly: (.alertResetTitleWeekly(account), .alertResetBodyWeekly(account))
        case .modelWeekly: (.alertResetTitleModel(account, modelLabel), .alertResetBodyModel(modelLabel, account))
        }
    }

    /// Label-free, percentage-free copy for privacy mode. Carries the event
    /// category (so the notification is still actionable) but nothing that
    /// identifies the account or its exact usage. The title is the app's
    /// name, which is never translated.
    private static func redactedText(for event: AlertEvent, locale: Locale) -> (title: String, body: String) {
        let body: LocalizedStringResource = switch event {
        case .threshold: .alertRedactedThreshold
        case .reset: .alertRedactedReset
        case .reauthRequired: .alertRedactedReauth
        case .rateLimited: .alertRedactedRateLimited
        case .spendThreshold: .alertRedactedSpend
        case .resetCreditAvailable: .alertRedactedResetCreditAvailable
        case .resetCreditExpiring: .alertRedactedResetCreditExpiring
        }
        return ("Ration", body.string(in: locale))
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
        case .resetCreditAvailable(let credit, _):
            return "\(base).resetCredit.\(credit.id).available"
        case .resetCreditExpiring(let credit):
            return "\(base).resetCredit.\(credit.id).expiring"
        }
    }

    /// Formats cents as a USD amount (Cursor bills in dollars) in the app
    /// language: `currency.usd` ("$50", "50 $" in French and Ukrainian), with
    /// that language's decimal separator and grouping, never the region's —
    /// en_FR still reads "$50". Drops fraction digits when the amount is a
    /// whole number of dollars, so round configured thresholds read as "$50"
    /// rather than "$50.00" in copy. See `UsageFormatters.usd`.
    ///
    /// `locale` is injectable so the formatting can be pinned in tests; it
    /// defaults to the running language for all production copy.
    static func dollars(_ cents: Int, locale: Locale = .autoupdatingCurrent) -> String {
        UsageFormatters.usd(cents: cents, alertStyle: true, locale: locale)
    }

    /// "Oct 22, 18:00" in the reader's locale. `locale`/`timeZone` injectable for tests.
    static func expiryText(_ date: Date, locale: Locale = .autoupdatingCurrent, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: .abbreviated, time: .shortened)
        style.locale = locale
        style.timeZone = timeZone
        return date.formatted(style)
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
