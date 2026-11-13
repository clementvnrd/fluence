import Foundation
import Testing

@testable import FluenceMeetingCore

/// The meeting being recorded or finalised has one writer, the controller; what the user
/// edits in the library meanwhile reaches its saves through the copy on disk (FLU-136).
struct LiveMeetingTests {
    static let start = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// The controller's copy: the original title, no notes, a transcript growing.
    static func live() -> Meeting {
        var meeting = Meeting(title: "Appel Zoom", startedAt: start, speakers: [.me(), .others])
        meeting.segments = [
            TranscriptSegment(source: .system, speakerID: Speaker.othersID, start: 0, end: 2, text: "Bonjour"),
            TranscriptSegment(source: .microphone, speakerID: Speaker.meID, start: 2, end: 4, text: "Salut"),
        ]
        return meeting
    }

    @Test("the user's notes, title and speaker names typed during the call survive the controller's save")
    func keepsTheUserEdits() throws {
        let live = Self.live()
        var stored = live
        stored.segments = Array(live.segments.prefix(1)) // the last autosave
        stored.title = "Point hebdo"
        stored.userNotes = "Relancer le devis"
        stored.speakers = [.me(), Speaker(id: Speaker.othersID, name: "Alice", nameSource: .user)]

        let saved = try #require(LiveMeeting.toSave(live, stored: stored, onDisk: true))

        #expect(saved.title == "Point hebdo")
        #expect(saved.userNotes == "Relancer le devis")
        #expect(saved.speakers.first { $0.id == Speaker.othersID }?.name == "Alice")
        #expect(saved.segments.count == 2) // the transcript is the controller's
    }

    @Test("after the final pass: diarized voices are kept, and a name the user gave survives where its voice still exists")
    func finalPassKeepsDiarizationAndUserNames() throws {
        var live = Self.live()
        live.speakers = [.me(), Speaker(id: "S1", name: "Bob", nameSource: .meetingWindow), Speaker(id: "S2")]
        var stored = Self.live()
        stored.speakers = [Speaker.me(named: "Clément"), Speaker(id: Speaker.othersID, name: "Alice", nameSource: .user)]

        let saved = try #require(LiveMeeting.toSave(live, stored: stored, onDisk: true))

        #expect(saved.speakers.map(\.id) == ["me", "S1", "S2"])
        #expect(saved.speakers.map(\.name) == ["Clément", "Bob", nil])
    }

    @Test("notes written by the generator are not wiped by a later controller save")
    func keepsGeneratedNotes() throws {
        var stored = Self.live()
        stored.notes = MeetingNotes(recap: "Résumé", nextSteps: [], decisions: [], openQuestions: [], generatedAt: Self.start, model: "test")
        let saved = try #require(LiveMeeting.toSave(Self.live(), stored: stored, onDisk: true))
        #expect(saved.notes?.recap == "Résumé")
    }

    @Test("a meeting deleted meanwhile is never written back")
    func deletedMeetingIsNotResurrected() {
        #expect(LiveMeeting.toSave(Self.live(), stored: nil, onDisk: false) == nil)
    }

    @Test("on disk but unreadable: the controller's copy is saved as before")
    func unreadableKeepsTheLiveCopy() throws {
        let saved = try #require(LiveMeeting.toSave(Self.live(), stored: nil, onDisk: true))
        #expect(saved.title == "Appel Zoom")
        #expect(saved.segments.count == 2)
    }
}
