import Foundation

/// What one captured billing summary says (see `TypeSafeBilling.parse`).
struct TypeSafeBillingReading: Equatable, Sendable {
    let credits: UsageCredits
    let spend: TypeSafeSpend
}

/// TypeSafe's billing, from the SUMMARY the capture script builds in the page
/// (`TypeSafeScripts.extractBilling`) out of the console's own server-action
/// answer. Only the permitted fields ever leave the page: `balance`, `spent`,
/// `cycleLabel`, `resetsInDays`, `autoPay` as "on"/"off", and per credit
/// `id`, `amount`, `remaining`, `expiresAt`, `reason`. US dollars.
enum TypeSafeBilling {
    /// The summary is small; anything larger (in UTF-8 bytes) is not from
    /// our script.
    static let maxMessageBytes = 65_536

    /// nil unless the summary carries a readable balance and spend.
    static func parse(summary: String, fetchedAt: Date) -> TypeSafeBillingReading? {
        guard
            summary.utf8.count <= maxMessageBytes,
            let payload = try? JSONDecoder().decode(TypeSafeBillingSummary.self, from: Data(summary.utf8)),
            let balance = payload.balance.flatMap(usd),
            let spent = payload.spent.flatMap(usd)
        else { return nil }
        // A missing or null list is NOT an empty one: a changed answer must
        // not read as "no grants" and prune alert memory.
        var complete = payload.credits != nil
        var grants: [UsageCreditGrant] = []
        var spentGrants: [UsageCreditGrant] = []
        for element in payload.credits ?? [] {
            guard
                let grant = element,
                let id = grant.id, !id.isEmpty,
                let remaining = grant.remaining.flatMap(usd)
            else {
                complete = false
                continue
            }
            let expiresAt: Date?
            if let raw = grant.expiresAt {
                guard let parsed = parseISO8601(raw) else {
                    complete = false
                    continue
                }
                expiresAt = parsed
            } else {
                expiresAt = nil
            }
            let kind: UsageCreditGrant.Kind = switch grant.reason {
            case "free_tier_credit": .free
            case "purchased_credits": .purchased
            default: .promotional
            }
            let parsed = UsageCreditGrant(
                id: id, kind: kind, remaining: remaining,
                granted: grant.amount.flatMap(usd), expiresAt: expiresAt
            )
            // A spent grant still belongs to the credit held (the menu-bar
            // gauge), but never to the warning, the card or Settings.
            if remaining.minorUnits > 0 { grants.append(parsed) } else { spentGrants.append(parsed) }
        }
        grants.sort { lhs, rhs in
            switch (lhs.expiresAt, rhs.expiresAt) {
            case let (l?, r?) where l != r: l < r
            case (_?, nil): true
            case (nil, _?): false
            default: lhs.id < rhs.id
            }
        }
        let autoRecharge: Bool? = switch payload.autoPay {
        case "on": true
        case "off": false
        default: nil
        }
        return TypeSafeBillingReading(
            credits: UsageCredits(fetchedAt: fetchedAt, balance: balance, grants: grants, complete: complete,
                                  spentGrants: spentGrants, readThisSession: true),
            spend: TypeSafeSpend(
                fetchedAt: fetchedAt,
                cycleSpent: spent,
                cycleLabel: payload.cycleLabel,
                resetsAt: payload.resetsInDays.flatMap { resetsAt(inDays: $0, from: fetchedAt) },
                autoRecharge: autoRecharge
            )
        )
    }

    /// Dollars as a decimal → cents, rounded to the nearest cent (half to
    /// even). nil for a negative or absurd amount.
    static func usd(_ dollars: Decimal) -> Money? {
        guard dollars >= 0, dollars < 1_000_000_000 else { return nil }
        var cents = dollars * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &cents, 0, .bankers)
        return Money(minorUnits: NSDecimalNumber(decimal: rounded).int64Value, currency: "USD", exponent: 2)
    }

    /// The console counts whole days to the next cycle: the start of the UTC
    /// day that many days after the answer arrived.
    static func resetsAt(inDays days: Int, from fetchedAt: Date) -> Date? {
        guard (0...366).contains(days) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = calendar.startOfDay(for: fetchedAt)
        return calendar.date(byAdding: .day, value: days, to: today)
    }

    static func parseISO8601(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) { return date }
        let whole = ISO8601DateFormatter()
        whole.formatOptions = [.withInternetDateTime]
        return whole.date(from: value)
    }
}

/// TypeSafe's per-day usage, as the in-page usage script returns it: rows of
/// `[yyyy-MM-dd, inputTokens, outputTokens, requests]`, already summed over
/// every API key in the page (key names and e-mails never leave it).
enum TypeSafeUsage {
    static func days(fromRows rows: [Any]) -> [TypeSafeDay]? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var days: [TypeSafeDay] = []
        for element in rows {
            guard
                let row = element as? [Any], row.count == 4,
                let text = row[0] as? String,
                let day = dayStart(text, calendar: calendar),
                let input = count(row[1]), let output = count(row[2]), let requests = count(row[3])
            else { return nil }
            days.append(TypeSafeDay(day: day, inputTokens: input, outputTokens: output, requests: requests))
        }
        return days.sorted { $0.day < $1.day }
    }

    private static func count(_ value: Any) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double < Double(Int.max / 2) else { return nil }
        return Int(double)
    }

    private static func dayStart(_ yyyyMMdd: String, calendar: Calendar) -> Date? {
        let parts = yyyyMMdd.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
        return calendar.date(from: DateComponents(year: y, month: m, day: d))
    }
}

// MARK: - The summary the capture script posts (lenient at every level)

private struct TypeSafeBillingSummary: Decodable {
    let balance: Decimal?
    let spent: Decimal?
    let cycleLabel: String?
    let resetsInDays: Int?
    let autoPay: String?
    /// nil: missing, null or not a list.
    let credits: [TypeSafeCreditSummary?]?

    enum CodingKeys: String, CodingKey { case balance, spent, cycleLabel, resetsInDays, autoPay, credits }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        balance = (try? c.decodeIfPresent(Decimal.self, forKey: .balance)) ?? nil
        spent = (try? c.decodeIfPresent(Decimal.self, forKey: .spent)) ?? nil
        cycleLabel = (try? c.decodeIfPresent(String.self, forKey: .cycleLabel)) ?? nil
        resetsInDays = (try? c.decodeIfPresent(Int.self, forKey: .resetsInDays)) ?? nil
        autoPay = (try? c.decodeIfPresent(String.self, forKey: .autoPay)) ?? nil
        credits = (try? c.decodeIfPresent([FailableCreditSummary].self, forKey: .credits))?.map(\.value)
    }
}

private struct FailableCreditSummary: Decodable {
    let value: TypeSafeCreditSummary?
    init(from decoder: any Decoder) throws { value = try? TypeSafeCreditSummary(from: decoder) }
}

private struct TypeSafeCreditSummary: Decodable {
    let id: String?
    let amount: Decimal?
    let remaining: Decimal?
    let expiresAt: String?
    let reason: String?
}
