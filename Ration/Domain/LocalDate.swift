import Foundation

/// A timezone-independent civil date — "July 15, 2026", not an instant.
///
/// `Date` is an absolute point in time, so persisting a holiday bound as a
/// `Date` makes it slide across the calendar when the user travels: a July 15
/// set in Paris resolves to July 14 in New York. Holidays are civil dates, so
/// they are stored as components and resolved to an instant only at evaluation
/// time, in whatever calendar/zone is current then.
struct LocalDate: Codable, Equatable, Comparable, Sendable, Hashable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// A `LocalDate` is a civil GREGORIAN date, so it always resolves through a
    /// Gregorian calendar — only the caller's TIME ZONE is borrowed. Using the
    /// caller's calendar *identifier* would let a non-Gregorian device (Hebrew,
    /// Islamic) produce components (e.g. month 13) that the Gregorian decode
    /// then rejects, resetting the whole settings file on the next load.
    private static func gregorian(_ calendar: Calendar) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    /// The civil date `date` falls on, as seen in `calendar`'s zone.
    init(_ date: Date, calendar: Calendar) {
        let components = Self.gregorian(calendar).dateComponents([.year, .month, .day], from: date)
        self.year = components.year ?? 1
        self.month = components.month ?? 1
        self.day = components.day ?? 1
    }

    /// Midnight at the start of this civil date, resolved in `calendar`'s zone.
    /// `nil` only for a non-existent date (e.g. a hand-edited Feb 30).
    func startOfDay(in calendar: Calendar) -> Date? {
        Self.gregorian(calendar).date(from: DateComponents(year: year, month: month, day: day))
    }

    static func < (lhs: LocalDate, rhs: LocalDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    // MARK: Codable — "YYYY-MM-DD", human-readable and stable in the JSON file.

    /// Supported civil years. Bounded deliberately: this is a user-picked
    /// holiday date, not an astronomical calendar.
    static let yearRange = 1...9999

    init(from decoder: any Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        func corrupt() -> DecodingError {
            DecodingError.dataCorrupted(
                .init(
                    codingPath: decoder.codingPath,
                    debugDescription: "Expected YYYY-MM-DD, got \(raw)"
                )
            )
        }
        // Exact, anchored parse. `split(separator:)` drops empty components, so
        // it would happily accept "2026--01-01" and read "-001-01-01" as a
        // positive year.
        let parts = raw.components(separatedBy: "-")
        guard
            parts.count == 3,
            parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            parts.allSatisfy({ $0.allSatisfy(\.isNumber) }),
            let year = Int(parts[0]),
            let month = Int(parts[1]),
            let day = Int(parts[2]),
            Self.yearRange.contains(year),
            (1...12).contains(month),
            (1...31).contains(day)
        else {
            throw corrupt()
        }
        // Reject dates that don't exist (e.g. Feb 30, Apr 31) rather than
        // persisting a range whose bound silently never resolves.
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = DateComponents(year: year, month: month, day: day)
        guard components.isValidDate(in: gregorian) else { throw corrupt() }
        self.init(year: year, month: month, day: day)
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(String(format: "%04d-%02d-%02d", year, month, day))
    }
}
