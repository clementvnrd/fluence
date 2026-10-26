import Foundation

/// A calendar event reduced to what choosing the current call needs (FLU-33). Built by the
/// app from EventKit; no EventKit here.
public struct CalendarCandidate: Sendable, Equatable {
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    /// The conferencing service its link, location or notes point to
    /// (`MeetingApps.conferencingService(in:)`), nil when none.
    public var service: String?

    public init(start: Date, end: Date, isAllDay: Bool = false, service: String?) {
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.service = service
    }
}

/// Which calendar event a recording belongs to (FLU-33).
///
/// Its title names the meeting and its invitees cap the voices and name them by
/// elimination, so the wrong event is worse than none: two overlapping calls, a Teams
/// stand-up running late while the user joins a Zoom, used to give the Zoom recording the
/// Teams invitees, by start time alone.
///
/// 1. **Eligible**: not all-day, has a conferencing link, has started or starts within
///    `earlyJoin`, has not ended.
/// 2. **The detected service decides** when it is known (`detectedService`, e.g. « Zoom »
///    for the Zoom app or « Google Meet » for a browser tab): only events whose link points
///    to that service qualify, and when none does, no event is used.
/// 3. **Time breaks ties**, and decides alone when the service is unknown (a recording
///    started by hand with no call app, a browser whose tab was not recognised): the event
///    that started last, then the one ending first, then the first listed.
public enum CalendarMatch {
    /// How early before its start an event already counts (joining a call early).
    public static let earlyJoin: TimeInterval = 5 * 60

    /// The index in `events` of the call the user is in at `now`, or nil.
    public static func current(_ events: [CalendarCandidate], now: Date, detectedService: String?) -> Int? {
        let eligible = events.indices.filter { index in
            let event = events[index]
            return !event.isAllDay
                && event.service != nil
                && event.start <= now.addingTimeInterval(earlyJoin)
                && event.end > now
        }
        let pool: [Int]
        if let detectedService {
            pool = eligible.filter { events[$0].service == detectedService }
        } else {
            pool = eligible
        }
        return pool.min { a, b in
            let x = events[a], y = events[b]
            if x.start != y.start { return x.start > y.start }
            if x.end != y.end { return x.end < y.end }
            return a < b
        }
    }
}

extension MeetingApps {
    /// The conferencing service a detected call is known to use, for matching it to a
    /// calendar event (FLU-33): the service a browser tab showed (« Google Meet »), or the
    /// native app's own name (« Zoom », « Microsoft Teams »). Nil for a browser whose tab
    /// was not recognised — its `service` is then just the browser's name.
    public static func callService(app: MeetingApp, service: String) -> String? {
        if app.isBrowser && service == app.name { return nil }
        return service
    }
}
