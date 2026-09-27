import Foundation

enum APIBudgetInputError: Error, Equatable {
    case unreadable, outOfRange

    func message(locale: Locale = .current) -> String {
        switch self {
        case .unreadable: LocalizedStringResource.apiSpendBudgetUnreadable.string(in: locale)
        case .outOfRange: LocalizedStringResource.apiSpendBudgetOutOfRange.string(in: locale)
        }
    }
}

/// Budget text → whole cents, in the user's own number format.
/// Never truncates: sub-cent or unreadable text is refused with a message.
enum APIBudgetInput {
    static func cents(from text: String, locale: Locale) -> Result<Int?, APIBudgetInputError> {
        var cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.isEmpty { return .success(nil) }
        cleaned = cleaned.replacingOccurrences(of: "US$", with: "").replacingOccurrences(of: "$", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let spaces: Set<Character> = [" ", "\u{00A0}", "\u{202F}"]
        let decimal = Character(locale.decimalSeparator ?? ".")
        var grouping = spaces
        if let separator = (locale.groupingSeparator ?? ",").first, separator != decimal { grouping.insert(separator) }
        // "." is read as a decimal point too wherever it is not the grouping mark.
        var decimals: Set<Character> = [decimal]
        if !grouping.contains(".") { decimals.insert(".") }

        let parts = cleaned.split(omittingEmptySubsequences: false, whereSeparator: { decimals.contains($0) })
        guard parts.count <= 2 else { return .failure(.unreadable) }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        let integer = parts[0]
        // A grouping mark must group thousands: "1,000" yes, "12,34" never.
        let groups = integer.split(omittingEmptySubsequences: false, whereSeparator: { grouping.contains($0) })
        guard let first = groups.first,
              groups.count == 1 || (1...3).contains(first.count) && groups.dropFirst().allSatisfy({ $0.count == 3 })
        else { return .failure(.unreadable) }
        let digits = groups.joined()
        func isDigits(_ text: String) -> Bool { text.allSatisfy { $0.isASCII && $0.isNumber } }
        guard !(digits.isEmpty && fraction.isEmpty), isDigits(digits), isDigits(fraction),
              let dollars = Decimal(string: "\(digits.isEmpty ? "0" : digits).\(fraction.isEmpty ? "0" : fraction)",
                                    locale: Locale(identifier: "en_US_POSIX")),
              APIMoney.fractionDigits(dollars) <= 2
        else { return .failure(.unreadable) }
        let cents = NSDecimalNumber(decimal: dollars * 100).intValue
        guard APIMoney.budgetRange.contains(cents) else { return .failure(.outOfRange) }
        return .success(cents)
    }

    /// Cents → the field's text in `locale` ("600", "600,5").
    static func text(forCents cents: Int?, locale: Locale = .current) -> String {
        guard let cents else { return "" }
        return (Decimal(cents) / 100).formatted(.number.precision(.fractionLength(0...2)).grouping(.never).locale(locale))
    }
}
