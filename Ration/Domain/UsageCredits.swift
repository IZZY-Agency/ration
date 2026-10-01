import Foundation

/// An exact amount of money: whole minor units (cents) of one currency, never
/// floating point. claude.ai reports its balances this way
/// (`{"amount_minor": 1000, "currency": "EUR", "exponent": 2}`).
struct Money: Codable, Equatable, Hashable, Sendable {
    let minorUnits: Int64
    /// Upper-cased ISO 4217 code.
    let currency: String
    /// Digits after the decimal point: 2 for EUR and USD, 0 for JPY.
    let exponent: Int

    static let exponentRange = 0...4

    /// nil for anything that cannot be an amount of money: a negative amount,
    /// a currency that is not three letters, an exponent out of range.
    init?(minorUnits: Int64, currency: String, exponent: Int) {
        let code = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard
            minorUnits >= 0,
            Self.exponentRange.contains(exponent),
            code.count == 3,
            code.unicodeScalars.allSatisfy({ ("A"..."Z").contains($0) })
        else { return nil }
        self.minorUnits = minorUnits
        self.currency = code
        self.exponent = exponent
    }

    /// Decoding goes through the same checks, so a hand-edited file cannot
    /// hold an amount the initialiser would refuse.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let money = Money(
            minorUnits: try c.decode(Int64.self, forKey: .minorUnits),
            currency: try c.decode(String.self, forKey: .currency),
            exponent: try c.decode(Int.self, forKey: .exponent)
        ) else {
            throw DecodingError.dataCorruptedError(forKey: .minorUnits, in: c, debugDescription: "Not an amount of money")
        }
        self = money
    }

    var decimalValue: Decimal {
        var value = Decimal(minorUnits)
        for _ in 0..<exponent { value /= 10 }
        return value
    }

    /// The total of `amounts`: nil for none, or when any two differ in
    /// currency or exponent, or the sum overflows. The one place amounts are
    /// added, so the card, the drop and the warning cannot disagree.
    static func sum(_ amounts: [Money]) -> Money? {
        guard var total = amounts.first else { return nil }
        for amount in amounts.dropFirst() {
            guard let next = total + amount else { return nil }
            total = next
        }
        return total
    }

    /// nil when the two are not the same currency with the same exponent.
    static func + (lhs: Money, rhs: Money) -> Money? {
        guard lhs.currency == rhs.currency, lhs.exponent == rhs.exponent else { return nil }
        let (sum, overflow) = lhs.minorUnits.addingReportingOverflow(rhs.minorUnits)
        guard !overflow else { return nil }
        return Money(minorUnits: sum, currency: lhs.currency, exponent: lhs.exponent)
    }
}

/// One grant of Claude usage credits with money left (claude.ai
/// `prepaid/credits` → `promo_tranches[]` / `tranches[]`). Ration only shows
/// these; buying or turning credits on happens on claude.ai.
struct UsageCreditGrant: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable {
        case promotional
        case purchased
        /// A recurring free allowance (TypeSafe's monthly credit).
        case free
    }

    /// Provider-issued id: the dedupe key for the expiry warning.
    let id: String
    let kind: Kind
    let remaining: Money
    /// nil: claude.ai did not say (or not in the balance's currency).
    let granted: Money?
    /// nil: this grant does not expire.
    let expiresAt: Date?
}

/// An account's usage credits as READ by one background read after a usage
/// fetch (see `AppModel.refreshUsageCreditsInBackground`).
///
/// `fetchedAt` is the read's own time, later than the snapshot's: freshness
/// is judged against `UsageEvidence.maxAge`, not by equality with the
/// snapshot's `fetchedAt` as resets are. A snapshot whose fetch could not
/// read credits carries the last reading forward unchanged (see
/// `UsageSnapshotStore.merged`).
struct UsageCredits: Codable, Equatable, Sendable {
    let fetchedAt: Date
    let balance: Money
    /// Grants with money left, soonest expiry first (never-expiring last).
    let grants: [UsageCreditGrant]
    /// false when at least one grant was malformed and skipped: the list is
    /// then not authoritative about ABSENCE, so alert memory is not pruned.
    let complete: Bool
    /// Grants fully spent (nothing left), kept apart so the warning, the card
    /// and Settings never show a $0.00 grant. Only the menu-bar credit gauge
    /// reads them: they still belong to the credit held (`CreditGaugeFacts`).
    /// TypeSafe only; empty in files written before 2026-10-01.
    let spentGrants: [UsageCreditGrant]
    /// The claude.ai organization this reading was applied for, IN MEMORY
    /// ONLY (never encoded, like `UsageSnapshot.organizationID`). A reading
    /// restored from disk has none, so it is display-only until this
    /// session reads the current organization's credits: the expiry warning
    /// requires it to match the snapshot's organization.
    let organizationID: String?
    /// Read by a live fetch in THIS session (TypeSafe reads its balance with
    /// the usage fetch). IN MEMORY ONLY: a reading restored from disk has
    /// false, so it is display-only until read again.
    let readThisSession: Bool

    enum CodingKeys: String, CodingKey { case fetchedAt, balance, grants, complete, spentGrants }

    init(
        fetchedAt: Date, balance: Money, grants: [UsageCreditGrant], complete: Bool,
        spentGrants: [UsageCreditGrant] = [], organizationID: String? = nil, readThisSession: Bool = false
    ) {
        self.fetchedAt = fetchedAt
        self.balance = balance
        self.grants = grants
        self.complete = complete
        self.spentGrants = spentGrants
        self.organizationID = organizationID
        self.readThisSession = readThisSession
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fetchedAt = try c.decode(Date.self, forKey: .fetchedAt)
        balance = try c.decode(Money.self, forKey: .balance)
        grants = try c.decode([UsageCreditGrant].self, forKey: .grants)
        complete = try c.decode(Bool.self, forKey: .complete)
        // Lenient: a missing or unreadable list only costs the gauge.
        spentGrants = ((try? c.decodeIfPresent([UsageCreditGrant].self, forKey: .spentGrants)) ?? nil) ?? []
        organizationID = nil
        readThisSession = false
    }

    /// Same reading, tagged with the organization it was applied for.
    func applied(for organizationID: String) -> UsageCredits {
        UsageCredits(fetchedAt: fetchedAt, balance: balance, grants: grants, complete: complete, spentGrants: spentGrants,
                     organizationID: organizationID, readThisSession: readThisSession)
    }

    /// Grants that still hold money at `now`, by local expiry.
    func grants(unexpiredAt now: Date) -> [UsageCreditGrant] {
        grants.filter { grant in
            grant.remaining.minorUnits > 0 && (grant.expiresAt.map { $0 > now } ?? true)
        }
    }
}

/// ChatGPT Codex credits, read with every usage fetch (`wham/usage` →
/// `credits`, verified live 2026-09-30). A count of credits, not money, and
/// with no expiry, so there is nothing to warn about: Ration only shows them.
struct CodexCredits: Codable, Equatable, Sendable {
    /// The usage fetch's own time (the same response).
    let fetchedAt: Date
    /// Credits left. 0 when `unlimited`.
    let balance: Decimal
    let unlimited: Bool

    /// Something worth a line: unlimited, or a balance above zero.
    var isShown: Bool { unlimited || balance > 0 }
}

/// TypeSafe's billing side (`TypeSafeProviderAdapter`): the current cycle as
/// the console's billing reports it.
struct TypeSafeSpend: Codable, Equatable, Sendable {
    /// When the billing answer arrived.
    let fetchedAt: Date
    /// `billing.spent`: what this cycle has cost so far.
    let cycleSpent: Money
    /// `billing.cycleLabel`, e.g. "September 2026" (TypeSafe's English;
    /// Settings shows its own month name and uses this only without a reset).
    let cycleLabel: String?
    /// Start of the next cycle, from `billing.resetsInDays` (whole days).
    let resetsAt: Date?
    /// Auto-recharge on (`billing.autoPay` set) or off; nil when unread.
    let autoRecharge: Bool?
}

/// TypeSafe's per-day usage (`GET /api/usage?granularity=day`), read apart
/// from the billing so either can fail alone.
struct TypeSafeDailyUsage: Codable, Equatable, Sendable {
    let fetchedAt: Date
    /// One entry per UTC day with usage, oldest first. A day inside the
    /// response's window with no entry had no usage; a day before
    /// `coverageStart` is unknown.
    let days: [TypeSafeDay]

    /// The console returns the last 30 days, today included.
    static let coverageDays = 30

    /// The first UTC day the response speaks for.
    var coverageStart: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: fetchedAt)
        return calendar.date(byAdding: .day, value: -(Self.coverageDays - 1), to: today) ?? today
    }
}

/// One day of TypeSafe usage, summed over every API key.
struct TypeSafeDay: Codable, Equatable, Sendable {
    /// UTC midnight of the day.
    let day: Date
    let inputTokens: Int
    let outputTokens: Int
    let requests: Int
}

/// TypeSafe's list price, as its console estimates spend: input tokens only,
/// output is free (docs.typesafe.ai and the console's Usage page, read
/// 2026-09-30).
enum TypeSafePrice {
    static let listedOn = "2026-09-30"
    /// US dollars per million input tokens.
    static let inputPerMillion = Decimal(string: "0.042")!

    /// Estimated dollars for `inputTokens`, as the console shows them.
    static func estimate(inputTokens: Int) -> Decimal {
        Decimal(inputTokens) * inputPerMillion / 1_000_000
    }
}
