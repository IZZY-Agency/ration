import Foundation

/// The UTC calendar month API spend is measured in.
struct UTCMonth: Hashable, Codable, Comparable, Sendable {
    let year: Int
    let month: Int

    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    init(containing date: Date) {
        let parts = Self.calendar.dateComponents([.year, .month], from: date)
        self.init(year: parts.year!, month: parts.month!)
    }

    var start: Date { Self.calendar.date(from: DateComponents(year: year, month: month, day: 1))! }
    var nextStart: Date { Self.calendar.date(byAdding: .month, value: 1, to: start)! }
    /// "2026-09" — the alert-memory month key.
    var key: String { String(format: "%04d-%02d", year, month) }

    static func < (lhs: UTCMonth, rhs: UTCMonth) -> Bool {
        (lhs.year, lhs.month) < (rhs.year, rhs.month)
    }
}

enum UTCDay {
    static func start(of date: Date) -> Date { UTCMonth.calendar.startOfDay(for: date) }
    static func nextStart(after date: Date) -> Date {
        UTCMonth.calendar.date(byAdding: .day, value: 1, to: start(of: date))!
    }
}
