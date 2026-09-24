import SwiftUI

/// The 7×24 weekly quiet-hours matrix. A selected cell means "no warm-up".
///
/// Display order follows `calendar.firstWeekday` (Monday-first locales etc.),
/// while storage stays on the fixed 1=Sunday...7=Saturday convention — so each
/// column carries its own `weekdayValue` rather than deriving it from the
/// column position, which would silently mislabel non-Sunday-first locales.
struct QuietHoursGrid: View {
    @Binding var selection: Set<Int>
    var calendar: Calendar = .autoupdatingCurrent

    private struct Column: Identifiable {
        let weekdayValue: Int // Calendar's 1...7
        let symbol: String
        var id: Int { weekdayValue }
    }

    private var columns: [Column] {
        let symbols = calendar.shortWeekdaySymbols // index 0 == Sunday
        guard symbols.count == 7 else { return [] }
        let first = calendar.firstWeekday // 1...7
        return (0..<7).map { offset in
            let weekdayValue = (first - 1 + offset) % 7 + 1
            return Column(weekdayValue: weekdayValue, symbol: symbols[weekdayValue - 1])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            header
            ForEach(0..<24, id: \.self) { hour in
                row(hour: hour)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 3) {
            Text("").frame(width: 28)
            ForEach(columns) { column in
                Button {
                    toggleDay(column.weekdayValue)
                } label: {
                    Text(column.symbol)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.creamDim)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .help("Toggle all of \(column.symbol)")
                .accessibilityLabel(Self.dayToggleAccessibilityLabel(weekday: column.weekdayValue, calendar: calendar))
            }
        }
    }

    private func row(hour: Int) -> some View {
        HStack(spacing: 3) {
            Button {
                toggleHour(hour)
            } label: {
                Text(String(format: "%02d", hour))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.creamDim)
                    .frame(width: 28, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .help("Toggle \(String(format: "%02d", hour)):00 on every day")
            .accessibilityLabel(Self.hourToggleAccessibilityLabel(hour: hour, locale: calendar.locale ?? .current))

            ForEach(columns) { column in
                cell(weekday: column.weekdayValue, symbol: column.symbol, hour: hour)
            }
        }
    }

    private func cell(weekday: Int, symbol: String, hour: Int) -> some View {
        let index = WarmUpQuietSchedule.cellIndex(weekday: weekday, hour: hour)
        let isQuiet = selection.contains(index)
        return Button {
            toggle(index)
        } label: {
            Rectangle()
                .fill(isQuiet ? Theme.gold : Theme.line)
                .frame(height: 14)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(symbol) \(String(format: "%02d", hour)):00")
        .accessibilityValue(isQuiet ? "quiet" : "warm-up allowed")
        .accessibilityAddTraits(.isToggle)
    }

    /// The day header's spoken label — "Toggle all Monday", the full day
    /// name rather than the drawn "Mon" (whose meaning was tooltip-only).
    static func dayToggleAccessibilityLabel(weekday: Int, calendar: Calendar) -> String {
        let names = calendar.weekdaySymbols // index 0 == Sunday
        let name = names.indices.contains(weekday - 1) ? names[weekday - 1] : "\(weekday)"
        return "Toggle all \(name)"
    }

    /// The hour header's spoken label — "Toggle all 9 AM" in a 12-hour
    /// locale, "Toggle all 09:00" in a 24-hour one — never the bare "09".
    static func hourToggleAccessibilityLabel(hour: Int, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = TimeZone(identifier: "UTC")
        // "j" is the locale's preferred hour; it carries a day period ("a")
        // only in 12-hour locales. A 24-hour hour alone reads "09", so those
        // get hour AND minutes.
        let preferred = DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale) ?? ""
        formatter.setLocalizedDateFormatFromTemplate(preferred.contains("a") ? "j" : "Hm")
        let date = Date(timeIntervalSince1970: TimeInterval(hour * 3_600))
        // The formatter separates "9" and "AM" with a narrow no-break space;
        // a plain one keeps the label ordinary text.
        let hourText = formatter.string(from: date)
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
        return "Toggle all \(hourText)"
    }

    private func toggle(_ index: Int) {
        if selection.contains(index) {
            selection.remove(index)
        } else {
            selection.insert(index)
        }
    }

    /// Whole column: if every hour is already quiet, clear the day; else set it.
    private func toggleDay(_ weekday: Int) {
        apply((0..<24).map { WarmUpQuietSchedule.cellIndex(weekday: weekday, hour: $0) })
    }

    /// Whole row across all seven days.
    private func toggleHour(_ hour: Int) {
        apply((1...7).map { WarmUpQuietSchedule.cellIndex(weekday: $0, hour: hour) })
    }

    private func apply(_ indices: [Int]) {
        if indices.allSatisfy({ selection.contains($0) }) {
            indices.forEach { selection.remove($0) }
        } else {
            indices.forEach { selection.insert($0) }
        }
    }
}
