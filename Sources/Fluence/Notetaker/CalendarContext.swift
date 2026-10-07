import EventKit
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
            return false
        }
    }

    /// The call happening around `now`: an event that has started (or starts within five
    /// minutes), has not ended, and carries a conferencing link. The latest-starting one
    /// wins when several overlap.
    func currentMeeting(now: Date = Date()) -> CalendarMeeting? {
        guard NotetakerSettings.shared.useCalendar, hasAccess else { return nil }
        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-12 * 3600),
            end: now.addingTimeInterval(15 * 60),
            calendars: nil
        )
        let candidates = store.events(matching: predicate).filter { event in
            !event.isAllDay
                && event.startDate <= now.addingTimeInterval(5 * 60)
                && event.endDate > now
                && Self.service(of: event) != nil
        }
        guard let event = candidates.max(by: { $0.startDate < $1.startDate }) else { return nil }

        let participants = event.attendees ?? []
        let user = participants.first(where: \.isCurrentUser).flatMap(Self.name)
        let attendees = participants
            .filter { !$0.isCurrentUser && $0.participantType != .room && $0.participantType != .resource }
            .compactMap(Self.name)
        return CalendarMeeting(
            title: event.title ?? "Meeting",
            attendees: attendees,
            userName: user,
            service: Self.service(of: event),
            end: event.endDate
        )
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
