import Foundation

/// A named civil-date range during which warm-up never fires. Whole days,
/// inclusive of both `start` and `end`.
struct HolidayRange: Codable, Equatable, Sendable, Identifiable {
    let id: UUID
    var start: LocalDate
    var end: LocalDate
    var label: String

    init(id: UUID = UUID(), start: LocalDate, end: LocalDate, label: String = "") {
        self.id = id
        self.start = start
        self.end = end
        self.label = label
    }
}

/// Global warm-up inhibition: a weekly hour mask plus holiday ranges.
///
/// This is a pure predicate, not a scheduler: `AutoStartPolicy` already runs on
/// every refresh, so a quiet period simply suppresses the decision and the
/// existing reactive logic fires once the period ends. Nothing is recorded
/// while quiet, so nothing is permanently suppressed.
struct WarmUpQuietSchedule: Equatable, Sendable {
    /// Quiet cells as `(weekday - 1) * 24 + hour`, 0...167, where `weekday` is
    /// `Calendar`'s 1=Sunday ... 7=Saturday. Empty = never quiet.
    let quietCells: Set<Int>
    let holidays: [HolidayRange]

    init(quietCells: Set<Int> = [], holidays: [HolidayRange] = []) {
        self.quietCells = quietCells
        self.holidays = holidays
    }

    /// The permissive default: warm-up is never inhibited. Also what an
    /// untouched/legacy install decodes to.
    static let allowAll = WarmUpQuietSchedule()

    static func cellIndex(weekday: Int, hour: Int) -> Int {
        (weekday - 1) * 24 + hour
    }

    func isQuiet(at date: Date, calendar: Calendar) -> Bool {
        if isHoliday(date, calendar: calendar) { return true }
        guard !quietCells.isEmpty else { return false }
        let weekday = calendar.component(.weekday, from: date)
        let hour = calendar.component(.hour, from: date)
        return quietCells.contains(Self.cellIndex(weekday: weekday, hour: hour))
    }

    private func isHoliday(_ date: Date, calendar: Calendar) -> Bool {
        for holiday in holidays {
            // A reversed range is meaningless — ignore it rather than trap.
            // The UI prevents creating one; a hand-edited file must not crash.
            guard holiday.start <= holiday.end else { continue }
            guard
                let lower = holiday.start.startOfDay(in: calendar),
                let endStart = holiday.end.startOfDay(in: calendar),
                // One CALENDAR day — not 86_400 seconds, which breaks on DST.
                let upper = calendar.date(byAdding: .day, value: 1, to: endStart)
            else {
                continue
            }
            // Half-open: `endOfDay` is not a real Foundation operation, and a
            // closed upper bound would wrongly include the next midnight.
            if date >= lower && date < upper { return true }
        }
        return false
    }
}
