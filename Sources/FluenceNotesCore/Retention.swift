import Foundation

/// How long meetings are kept. Stored as `NotetakerSettings.retentionDays` (`nil` = forever).
public enum RetentionChoice: Int, Sendable, CaseIterable, Identifiable, Hashable {
    case forever = 0
    case week = 7
    case month = 30
    case quarter = 90
    case year = 365

    public var id: Int { rawValue }

    /// `nil` keeps everything.
    public var days: Int? { self == .forever ? nil : rawValue }

    /// The choice for a stored value; nil when the value is not one of the presets.
    public init?(days: Int?) {
        guard let days, days > 0 else { self = .forever; return }
        self.init(rawValue: days)
    }

    public var title: String {
        switch self {
        case .forever: "Forever"
        case .week: "7 days"
        case .month: "30 days"
        case .quarter: "90 days"
        case .year: "1 year"
        }
    }
}

public enum Retention {
    /// Meetings that started before this are deleted. Same arithmetic as
    /// `MeetingStore.purge(olderThan:)`: whole 24-hour days back from `now`.
    public static func cutoff(days: Int?, now: Date) -> Date? {
        guard let days, days > 0 else { return nil }
        return now.addingTimeInterval(-Double(days) * 86_400)
    }

    /// How many of `dates` a retention of `days` would delete now — shown before the user
    /// confirms a shorter retention.
    public static func expiredCount(_ dates: [Date], days: Int?, now: Date) -> Int {
        guard let cutoff = cutoff(days: days, now: now) else { return 0 }
        return dates.count { $0 < cutoff }
    }
}
