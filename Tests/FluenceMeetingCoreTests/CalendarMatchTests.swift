import Foundation
import Testing

@testable import FluenceMeetingCore

/// FLU-33: the calendar event a recording belongs to.
struct CalendarMatchTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    func event(_ startMinutes: Double, _ endMinutes: Double, _ service: String?, allDay: Bool = false) -> CalendarCandidate {
        CalendarCandidate(
            start: now.addingTimeInterval(startMinutes * 60),
            end: now.addingTimeInterval(endMinutes * 60),
            isAllDay: allDay,
            service: service
        )
    }

    @Test("the event on the detected app wins over a later one on another app")
    func detectedServiceWins() {
        let events = [event(-30, 15, "Zoom"), event(-2, 30, "Microsoft Teams")]
        #expect(CalendarMatch.current(events, now: now, detectedService: "Zoom") == 0)
        #expect(CalendarMatch.current(events, now: now, detectedService: "Microsoft Teams") == 1)
    }

    @Test("no event on the detected app: none is used")
    func noMatchingEvent() {
        let events = [event(-10, 20, "Microsoft Teams")]
        #expect(CalendarMatch.current(events, now: now, detectedService: "Zoom") == nil)
        #expect(CalendarMatch.current(events, now: now, detectedService: "Discord") == nil)
    }

    @Test("an unknown service falls back to time: the latest start")
    func unknownService() {
        let events = [event(-30, 15, "Zoom"), event(-2, 30, "Microsoft Teams")]
        #expect(CalendarMatch.current(events, now: now, detectedService: nil) == 1)
    }

    @Test("two events on the same app: the latest start, then the earliest end")
    func timeTieBreak() {
        let events = [event(-30, 30, "Google Meet"), event(-5, 60, "Google Meet"), event(-5, 25, "Google Meet")]
        #expect(CalendarMatch.current(events, now: now, detectedService: "Google Meet") == 2)
    }

    @Test("what is never eligible: all-day, no link, over, or more than five minutes ahead")
    func eligibility() {
        #expect(CalendarMatch.current([event(-60, 600, "Zoom", allDay: true)], now: now, detectedService: "Zoom") == nil)
        #expect(CalendarMatch.current([event(-5, 30, nil)], now: now, detectedService: nil) == nil)
        #expect(CalendarMatch.current([event(-60, 0, "Zoom")], now: now, detectedService: "Zoom") == nil)
        #expect(CalendarMatch.current([event(6, 60, "Zoom")], now: now, detectedService: "Zoom") == nil)
        #expect(CalendarMatch.current([event(5, 60, "Zoom")], now: now, detectedService: "Zoom") == 0)
    }

    @Test("an empty calendar")
    func empty() {
        #expect(CalendarMatch.current([], now: now, detectedService: "Zoom") == nil)
    }

    @Test("the service a detected call is known to use")
    func callService() {
        let zoom = MeetingApps.identify("us.zoom.xos")!
        let chrome = MeetingApps.identify("com.google.Chrome")!
        #expect(MeetingApps.callService(app: zoom, service: "Zoom") == "Zoom")
        #expect(MeetingApps.callService(app: chrome, service: "Google Meet") == "Google Meet")
        #expect(MeetingApps.callService(app: chrome, service: "Google Chrome") == nil)
    }

    @Test("every native app's name a calendar link can point to is spelled the same")
    func namesAgree() {
        let zoomLink = MeetingApps.conferencingService(in: "https://us02web.zoom.us/j/123")
        let teamsLink = MeetingApps.conferencingService(in: "https://teams.microsoft.com/l/meetup-join/abc")
        #expect(zoomLink == MeetingApps.identify("us.zoom.xos")?.name)
        #expect(teamsLink == MeetingApps.identify("com.microsoft.teams2")?.name)
        #expect(MeetingApps.conferencingService(in: "https://meet.google.com/abc-defg-hij")
            == MeetingApps.meetingService(inWindowTitle: "Meet – abc-defg-hij"))
    }
}
