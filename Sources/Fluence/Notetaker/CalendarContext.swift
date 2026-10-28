import EventKit
import FluenceMeetingCore
import Foundation

/// The calendar event the user is in right now, when it is a call: its title and the
/// people invited. Read only when `NotetakerSettings.useCalendar` is on; full access is
/// requested the first time it is needed, never at launch.
struct CalendarMeeting: Sendable {
    var title: String
    /// Display names of the attendees, the user excluded.
    var attendees: [String]
    /// The user's own name as the calendar knows it, to exclude from window participants.
    var userName: String?
    var service: String?
    var end: Date
}

/// A call coming up in the calendar.
struct UpcomingCall: Identifiable, Sendable, Equatable {
    let id: String
    var title: String
    var start: Date
    var end: Date
    var service: String
    var attendees: [String]
}

@MainActor
final class CalendarContext {
    static let shared = CalendarContext()

    private let store = EKEventStore()
    private var askedThisLaunch = false

    var hasAccess: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    /// Asks once per launch, and only while the setting is on.
    func requestAccessIfNeeded() async -> Bool {
        guard NotetakerSettings.shared.useCalendar else { return false }
        if hasAccess { return true }
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined, !askedThisLaunch else { return false }
        askedThisLaunch = true
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            Log.app.error("calendar access request failed: \(error.localizedDescription, privacy: .public)")
            Diagnostics.error("calendar.request", error)
            return false
        }
    }

    /// The call happening around `now`: an event that has started (or starts within five
    /// minutes), has not ended, and carries a conferencing link. When the call's service is
    /// known (`service`, « Zoom », « Google Meet »…) only an event pointing to it qualifies;
    /// the latest-starting one wins when several do (`CalendarMatch`, FLU-33).
    func currentMeeting(now: Date = Date(), service: String? = nil) -> CalendarMeeting? {
        guard NotetakerSettings.shared.useCalendar, hasAccess else { return nil }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-12 * 3600),
            end: now.addingTimeInterval(15 * 60),
            calendars: nil
        )
        let events = store.events(matching: predicate)
        let candidates = events.map { event in
            CalendarCandidate(start: event.startDate, end: event.endDate, isAllDay: event.isAllDay, service: Self.service(of: event))
        }
        guard let index = CalendarMatch.current(candidates, now: now, detectedService: service) else {
            if service != nil, CalendarMatch.current(candidates, now: now, detectedService: nil) != nil {
                Log.app.info("calendar: an event is on now, but not on the detected app; none used")
            }
            return nil
        }
        let event = events[index]

        let participants = event.attendees ?? []
        let user = participants.first(where: \.isCurrentUser).flatMap(Self.name)
        let attendees = participants
            .filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
            .compactMap(Self.name)
        return CalendarMeeting(
            title: event.title ?? "Réunion",
            attendees: attendees,
            userName: user,
            service: Self.service(of: event),
            end: event.endDate
        )
    }

    /// Calls in the calendar over the next `days`: events with a conferencing link, not
    /// all-day, not already over. Read only while `useCalendar` is on and access is granted;
    /// for the "À venir" list (FLU-12), never stored.
    func upcomingCalls(now: Date = Date(), days: Int = 7) -> [UpcomingCall] {
        guard NotetakerSettings.shared.useCalendar, hasAccess else { return [] }
        let predicate = store.predicateForEvents(
            withStart: now,
            end: now.addingTimeInterval(Double(days) * 86_400),
            calendars: nil
        )
        return store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.endDate > now }
            .compactMap { event -> UpcomingCall? in
                guard let service = Self.service(of: event) else { return nil }
                let attendees = (event.attendees ?? [])
                    .filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
                    .compactMap(Self.name)
                return UpcomingCall(
                    id: (event.calendarItemExternalIdentifier ?? event.eventIdentifier ?? UUID().uuidString)
                        + "@\(event.startDate.timeIntervalSince1970)",
                    title: event.title ?? "Réunion",
                    start: event.startDate,
                    end: event.endDate,
                    service: service,
                    attendees: attendees
                )
            }
            .sorted { $0.start < $1.start }
    }

    private static func service(of event: EKEvent) -> String? {
        let text = [event.url?.absoluteString, event.location, event.notes].compactMap { $0 }.joined(separator: "\n")
        return MeetingApps.conferencingService(in: text)
    }

    /// The participant's name, or the local part of their e-mail address.
    private static func name(_ participant: EKParticipant) -> String? {
        if let name = participant.name?.trimmingCharacters(in: .whitespaces), !name.isEmpty, !name.contains("@") {
            return name
        }
        let address = participant.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        guard let local = address.split(separator: "@").first, !local.isEmpty else { return nil }
        return local.split(whereSeparator: { $0 == "." || $0 == "_" })
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}
