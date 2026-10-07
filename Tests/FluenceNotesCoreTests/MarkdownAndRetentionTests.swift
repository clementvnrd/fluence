import Foundation
import Testing

@testable import FluenceNotesCore

struct MarkdownTests {
    static let paris = TimeZone(identifier: "Europe/Paris")!
    // 2026-10-07 12:30 UTC = 14:30 in Paris.
    static let date = Date(timeIntervalSince1970: 1_791_376_200)

    static func meeting(notes: FinalNotesDraft?, language: NotesLanguage = .english, userNotes: String = "") -> MarkdownMeeting {
        MarkdownMeeting(
            title: "Weekly *sync*",
            startedAt: date,
            duration: 3_900,
            participants: ["You", "Marie"],
            language: language,
            notes: notes,
            userNotes: userNotes,
            transcript: [
                TranscriptLine(start: 0, speaker: "You", text: "Hello."),
                TranscriptLine(start: 75, speaker: "Marie", text: "Let's ship_it\nnow."),
            ],
            timeZone: paris
        )
    }

    @Test func fullDocument() {
        let notes = FinalNotesDraft(
            recap: "We agreed to ship.\n\nMarie sends the quote.",
            nextSteps: [ActionDraft(text: "Send the quote", owner: "Marie", due: "Friday"), ActionDraft(text: "Book a room")],
            decisions: ["Ship on Friday"],
            openQuestions: []
        )
        let markdown = MarkdownRenderer.render(Self.meeting(notes: notes, userNotes: "- check *budget*"))
        #expect(markdown == """
            # Weekly \\*sync\\*

            - **Date:** 2026-10-07 14:30
            - **Duration:** 1 h 05 min
            - **Participants:** You, Marie

            ## Recap

            We agreed to ship.

            Marie sends the quote.

            ## Next steps

            - [ ] Send the quote — **Marie** (due: Friday)
            - [ ] Book a room

            ## Decisions

            - Ship on Friday

            ## Open questions

            _None._

            ## My notes

            - check *budget*

            ## Transcript

            **[00:00] You:** Hello.

            **[01:15] Marie:** Let's ship\\_it now.

            """)
    }

    @Test func withoutNotesSaysSoAndKeepsTranscript() {
        let markdown = MarkdownRenderer.render(Self.meeting(notes: nil))
        #expect(markdown.contains("_No notes were generated for this meeting._"))
        #expect(!markdown.contains("## Recap"))
        #expect(!markdown.contains("## My notes"))
        #expect(markdown.contains("## Transcript"))
    }

    @Test func frenchLabels() {
        let markdown = MarkdownRenderer.render(Self.meeting(
            notes: FinalNotesDraft(recap: "Ok.", nextSteps: [ActionDraft(text: "Envoyer", owner: nil, due: "lundi")]),
            language: .french
        ))
        #expect(markdown.contains("## Récapitulatif"))
        #expect(markdown.contains("- [ ] Envoyer (échéance: lundi)"))
        #expect(markdown.contains("- **Durée:** 1 h 05 min"))
        #expect(markdown.contains("## Transcription"))
    }

    @Test func filenames() {
        #expect(MarkdownRenderer.filename(title: "Weekly: sync / Q4?", date: Self.date, timeZone: Self.paris)
            == "2026-10-07 Weekly sync Q4.md")
        #expect(MarkdownRenderer.filename(title: " ... ", date: Self.date, timeZone: Self.paris) == "2026-10-07 Meeting.md")
    }

    @Test func durations() {
        #expect(DurationText.format(0) == "0 min")
        #expect(DurationText.format(20) == "< 1 min")
        #expect(DurationText.format(45 * 60) == "45 min")
        #expect(DurationText.format(2 * 3600 + 5 * 60) == "2 h 05 min")
    }
}

struct RetentionTests {
    let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test func choices() {
        #expect(RetentionChoice.allCases.map(\.days) == [nil, 7, 30, 90, 365])
        #expect(RetentionChoice(days: nil) == .forever)
        #expect(RetentionChoice(days: 0) == .forever)
        #expect(RetentionChoice(days: 30) == .month)
        #expect(RetentionChoice(days: 14) == nil)
    }

    @Test func cutoffAndCount() {
        #expect(Retention.cutoff(days: nil, now: now) == nil)
        #expect(Retention.cutoff(days: 7, now: now) == now.addingTimeInterval(-7 * 86_400))
        let dates = [1, 6, 8, 40, 400].map { now.addingTimeInterval(-Double($0) * 86_400) }
        #expect(Retention.expiredCount(dates, days: nil, now: now) == 0)
        #expect(Retention.expiredCount(dates, days: 7, now: now) == 3)
        #expect(Retention.expiredCount(dates, days: 30, now: now) == 2)
        #expect(Retention.expiredCount(dates, days: 365, now: now) == 1)
    }
}

struct ConsentTests {
    @Test func texts() {
        #expect(ConsentNotice.text(.french).hasPrefix("Je prends des notes de cette réunion avec Fluence"))
        #expect(ConsentNotice.text(.french).contains("rien n'est envoyé sur Internet"))
        #expect(ConsentNotice.text(.english).contains("nothing is sent over the Internet"))
        #expect(ConsentNotice.bilingual == ConsentNotice.text(.french) + "\n\n" + ConsentNotice.text(.english))
    }
}
