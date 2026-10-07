import Foundation

/// How long finished dictations are kept on disk.
///
/// A month by default: long enough to find something you dictated last week, short enough
/// that the history isn't quietly an archive of everything you've ever said.
public enum HistoryRetention: String, CaseIterable, Sendable {
    /// Nothing is written to disk. The current session is still listed until quit.
    case never
    case day
    case month
    case forever

    public static let `default`: HistoryRetention = .month

    /// Whether finished dictations are written to disk at all.
    public var persists: Bool { self != .never }

    /// Runs dated before this are purged; nil keeps everything.
    public func cutoff(now: Date) -> Date? {
        switch self {
        case .never: now
        case .day: now.addingTimeInterval(-24 * 60 * 60)
        case .month: now.addingTimeInterval(-30 * 24 * 60 * 60)
        case .forever: nil
        }
    }

    /// Whether a run dated `date` survives a purge at `now`.
    public func keeps(_ date: Date, now: Date) -> Bool {
        guard let cutoff = cutoff(now: now) else { return true }
        return date >= cutoff
    }
}
