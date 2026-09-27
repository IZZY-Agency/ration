import Foundation

/// Money for API spend: `Decimal` cents, never `Double`.
enum APIMoney {
    /// $1,000,000 per result, in cents.
    static let maxResultCents: Decimal = 100_000_000
    /// $10,000,000 per monthly total, in cents.
    static let maxMonthCents: Decimal = 1_000_000_000
    static let maxFractionDigits = 12
    /// A budget is 1 cent … $10,000,000.
    static let budgetRange = 1...1_000_000_000

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Anthropic `amount`: a plain decimal string in CENTS.
    static func anthropicCents(_ text: String) throws -> Decimal {
        let isPlain = !text.isEmpty
            && text.filter({ $0 == "." }).count <= 1
            && text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") })
        guard isPlain, let value = Decimal(string: text, locale: posix),
              fractionDigits(value) <= maxFractionDigits
        else { throw APISpendError.integrationChanged(.amountOutOfRange) }
        try checkResult(value)
        return value
    }

    /// OpenAI `amount.value`: DOLLARS, decoded straight into `Decimal` by `JSONDecoder`.
    static func openAICents(dollars: Decimal) throws -> Decimal {
        guard !dollars.isNaN, fractionDigits(dollars) <= maxFractionDigits else {
            throw APISpendError.integrationChanged(.amountOutOfRange)
        }
        let cents = dollars * 100
        try checkResult(cents)
        return cents
    }

    static func checkMonthTotal(_ cents: Decimal) throws {
        guard !cents.isNaN, cents >= 0, cents <= maxMonthCents else {
            throw APISpendError.integrationChanged(.amountOutOfRange)
        }
    }

    private static func checkResult(_ cents: Decimal) throws {
        guard !cents.isNaN, cents >= 0, cents <= maxResultCents else {
            throw APISpendError.integrationChanged(.amountOutOfRange)
        }
    }

    static func roundedCents(_ cents: Decimal) -> Int { whole(cents, .plain) }
    static func flooredCents(_ cents: Decimal) -> Int { whole(cents, .down) }

    /// Unrounded percent of budget spent.
    static func exactPercent(spentCents: Decimal, budgetCents: Int) -> Decimal {
        spentCents * 100 / Decimal(budgetCents)
    }

    static func wholePercent(_ percent: Decimal, _ mode: NSDecimalNumber.RoundingMode) -> Int {
        whole(percent, mode)
    }

    /// Significant fraction digits (trailing zeros ignored).
    static func fractionDigits(_ value: Decimal) -> Int {
        let text = "\(value)"
        guard let dot = text.firstIndex(of: ".") else { return 0 }
        return text[text.index(after: dot)...].reversed().drop(while: { $0 == "0" }).count
    }

    private static func whole(_ value: Decimal, _ mode: NSDecimalNumber.RoundingMode) -> Int {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, 0, mode)
        return NSDecimalNumber(decimal: result).intValue
    }
}
