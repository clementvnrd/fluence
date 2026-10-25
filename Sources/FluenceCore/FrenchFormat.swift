import Foundation

/// Numbers, durations and counts written the French way, for the UI (FLU-12).
///
/// Deterministic on purpose — no `NumberFormatter` or locale lookup — so what the owner
/// approved on the mock-ups ("0,62 s", "1 h 05", "42 min") is what every Mac shows, whatever
/// its region settings.
public enum FrenchFormat {
    /// Non-breaking space: between a number and its unit, so "0,62 s" never wraps.
    public static let space = "\u{00A0}"

    /// "0,62 s": seconds with a decimal comma.
    public static func seconds(_ value: Double, fractionDigits: Int = 2) -> String {
        let clamped = value.isFinite ? max(0, value) : 0
        let text = String(format: "%.\(max(0, fractionDigits))f", clamped)
            .replacingOccurrences(of: ".", with: ",")
        return text + space + "s"
    }

    /// "3,2 Go", "632 Mo", "20 Ko": decimal units, as the Finder counts them. One decimal
    /// from a gigabyte up, whole numbers below.
    public static func bytes(_ value: Int64) -> String {
        let bytes = Double(max(0, value))
        if bytes >= 999_500_000 {
            return String(format: "%.1f", bytes / 1e9).replacingOccurrences(of: ".", with: ",") + space + "Go"
        }
        if bytes >= 999_500 { return "\(Int((bytes / 1e6).rounded()))" + space + "Mo" }
        if bytes >= 1_000 { return "\(Int((bytes / 1e3).rounded()))" + space + "Ko" }
        return "\(Int(bytes))" + space + "o"
    }

    /// Whole seconds to show. NaN, the infinities and negatives read as 0, anything past
    /// `Int32.max` seconds (68 years) as that: converting a larger `Double` to `Int` crashes,
    /// and a damaged imported transcript can carry any number (FLU-27).
    static func wholeSeconds(_ interval: TimeInterval, _ rule: FloatingPointRoundingRule) -> Int {
        guard interval.isFinite else { return 0 }
        return Int(min(max(0, interval), TimeInterval(Int32.max)).rounded(rule))
    }

    /// A meeting length: "45 s", "42 min", "1 h", "1 h 05".
    public static func duration(_ interval: TimeInterval) -> String {
        let total = wholeSeconds(interval, .toNearestOrAwayFromZero)
        if total < 60 { return "\(total)\(space)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)\(space)min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0
            ? "\(hours)\(space)h"
            : "\(hours)\(space)h\(space)" + String(format: "%02d", rest)
    }

    /// A running clock: "00:42", "12:47", "1:02:03".
    public static func clock(_ interval: TimeInterval) -> String {
        let total = wholeSeconds(interval, .down)
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// A position in a transcript, always with hours: "00:00:04".
    public static func timecode(_ interval: TimeInterval) -> String {
        let total = wholeSeconds(interval, .down)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    /// « texte », with the non-breaking spaces French puts inside the guillemets.
    public static func quoted(_ text: String) -> String {
        "«\(space)\(text)\(space)»"
    }

    /// "1 réunion", "3 réunions". French takes the singular for 0 and 1.
    public static func count(_ value: Int, _ singular: String, _ plural: String? = nil) -> String {
        "\(value)\(space)" + (abs(value) > 1 ? plural ?? singular + "s" : singular)
    }
}

/// Day and week headings, and the short dates of lists, in French (FLU-12).
///
/// Names are spelled out here rather than taken from a `DateFormatter`, for the same reason
/// as `FrenchFormat`. The calendar is passed in, so tests pin the time zone; the app uses
/// `FrenchDates.calendar`, whose weeks start on Monday.
public enum FrenchDates {
    /// The current calendar with French weeks (Monday first).
    public static var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    static let weekdays = ["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"]
    static let weekdaysShort = ["dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam."]
    static let months = [
        "janvier", "février", "mars", "avril", "mai", "juin",
        "juillet", "août", "septembre", "octobre", "novembre", "décembre",
    ]
    static let monthsShort = [
        "janv.", "févr.", "mars", "avr.", "mai", "juin",
        "juil.", "août", "sept.", "oct.", "nov.", "déc.",
    ]

    // MARK: Days

    /// The heading a dictation is filed under.
    public enum DayGroup: Hashable, Sendable {
        case today
        case yesterday
        /// Any other day, by its start.
        case day(Date)
    }

    public static func dayGroup(for date: Date, now: Date, calendar: Calendar) -> DayGroup {
        if calendar.isDate(date, inSameDayAs: now) { return .today }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return .yesterday
        }
        return .day(calendar.startOfDay(for: date))
    }

    /// "Aujourd'hui", "Hier", "Lundi 5 octobre", "Mardi 3 mars 2025" (the year only when it
    /// is not the current one).
    public static func label(_ group: DayGroup, now: Date, calendar: Calendar) -> String {
        switch group {
        case .today: return "Aujourd'hui"
        case .yesterday: return "Hier"
        case .day(let date):
            return capitalized(longDay(date, now: now, calendar: calendar))
        }
    }

    /// Items grouped by day, in the order they arrive (newest first in, newest first out).
    public static func groupByDay<Item>(
        _ items: [Item],
        date: (Item) -> Date,
        now: Date,
        calendar: Calendar
    ) -> [Grouped<DayGroup, Item>] {
        group(items) { dayGroup(for: date($0), now: now, calendar: calendar) }
    }

    // MARK: Weeks

    /// The heading a meeting is filed under.
    public enum WeekGroup: Hashable, Sendable {
        case thisWeek
        case lastWeek
        /// Older: by month.
        case month(year: Int, month: Int)
    }

    public static func weekGroup(for date: Date, now: Date, calendar: Calendar) -> WeekGroup {
        if let week = calendar.dateInterval(of: .weekOfYear, for: now) {
            if date >= week.start { return .thisWeek }
            if let previous = calendar.date(byAdding: .day, value: -7, to: week.start), date >= previous {
                return .lastWeek
            }
        }
        let parts = calendar.dateComponents([.year, .month], from: date)
        return .month(year: parts.year ?? 0, month: parts.month ?? 1)
    }

    /// "Cette semaine", "Semaine dernière", "Septembre 2026".
    public static func label(_ group: WeekGroup) -> String {
        switch group {
        case .thisWeek: return "Cette semaine"
        case .lastWeek: return "Semaine dernière"
        case .month(let year, let month):
            return capitalized(months[(month - 1 + 12) % 12]) + " \(year)"
        }
    }

    public static func groupByWeek<Item>(
        _ items: [Item],
        date: (Item) -> Date,
        now: Date,
        calendar: Calendar
    ) -> [Grouped<WeekGroup, Item>] {
        group(items) { weekGroup(for: date($0), now: now, calendar: calendar) }
    }

    // MARK: Short and long dates

    /// A list row's date: "Aujourd'hui, 10:00", "Hier, 16:30", "Lun. 5 oct., 14:00",
    /// "Jeu. 1er oct., 09:30", "12 mars 2025, 14:00".
    public static func relativeDayTime(_ date: Date, now: Date, calendar: Calendar) -> String {
        let time = self.time(date, calendar: calendar)
        switch dayGroup(for: date, now: now, calendar: calendar) {
        case .today: return "Aujourd'hui, \(time)"
        case .yesterday: return "Hier, \(time)"
        case .day:
            let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
            let day = dayNumber(parts.day ?? 1)
            let month = monthsShort[((parts.month ?? 1) - 1 + 12) % 12]
            if parts.year != calendar.component(.year, from: now) {
                return "\(day) \(months[((parts.month ?? 1) - 1 + 12) % 12]) \(parts.year ?? 0), \(time)"
            }
            let weekday = capitalized(weekdaysShort[((parts.weekday ?? 1) - 1 + 7) % 7])
            return "\(weekday) \(day) \(month), \(time)"
        }
    }

    /// A meeting page's date: "Mercredi 7 octobre 2026, 10:00".
    public static func fullDateTime(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let weekday = capitalized(weekdays[((parts.weekday ?? 1) - 1 + 7) % 7])
        let month = months[((parts.month ?? 1) - 1 + 12) % 12]
        return "\(weekday) \(dayNumber(parts.day ?? 1)) \(month) \(parts.year ?? 0), \(time(date, calendar: calendar))"
    }

    /// "09:30".
    public static func time(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    // MARK: Helpers

    /// "lundi 5 octobre", with the year when it is not `now`'s.
    static func longDay(_ date: Date, now: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .weekday], from: date)
        let weekday = weekdays[((parts.weekday ?? 1) - 1 + 7) % 7]
        let month = months[((parts.month ?? 1) - 1 + 12) % 12]
        var text = "\(weekday) \(dayNumber(parts.day ?? 1)) \(month)"
        if parts.year != calendar.component(.year, from: now) { text += " \(parts.year ?? 0)" }
        return text
    }

    /// French writes the first of the month "1er".
    static func dayNumber(_ day: Int) -> String { day == 1 ? "1er" : "\(day)" }

    static func capitalized(_ text: String) -> String {
        text.prefix(1).uppercased() + text.dropFirst()
    }

    private static func group<Item, Key: Hashable>(
        _ items: [Item],
        by key: (Item) -> Key
    ) -> [Grouped<Key, Item>] {
        var result: [Grouped<Key, Item>] = []
        var index: [Key: Int] = [:]
        for item in items {
            let k = key(item)
            if let i = index[k] {
                result[i].items.append(item)
            } else {
                index[k] = result.count
                result.append(Grouped(key: k, items: [item]))
            }
        }
        return result
    }
}

/// Items under one heading, in their original order.
public struct Grouped<Key: Hashable, Item>: Identifiable {
    public let key: Key
    public var items: [Item]
    public var id: Key { key }
}
