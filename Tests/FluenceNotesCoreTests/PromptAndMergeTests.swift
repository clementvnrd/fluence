import Foundation
import Testing

@testable import FluenceNotesCore

struct LanguageTests {
    @Test func tagWins() {
        #expect(NotesLanguage.detect(bcp47: "fr-FR", sample: "the and the and") == .french)
        #expect(NotesLanguage.detect(bcp47: "en_GB", sample: "le la les des") == .english)
    }

    @Test func transcriptDecidesOtherwise() {
        let french = "Alors je pense que c'est bien, on va faire la démo avec les clients et vous nous dites."
        let english = "So I think that is fine, we will do the demo with the clients and you tell us."
        #expect(NotesLanguage.detect(bcp47: nil, sample: french) == .french)
        #expect(NotesLanguage.detect(bcp47: "de-DE", sample: french) == .french)
        #expect(NotesLanguage.detect(bcp47: nil, sample: english) == .english)
        #expect(NotesLanguage.detect(bcp47: nil, sample: "") == .english)
    }
}

struct PromptTests {
    let context = NotesContext(
        title: "Point client",
        participants: ["You", "Marie"],
        userNotes: "Budget validé ?",
        language: .french,
        template: .clientCall
    )
    let chunk = TranscriptChunk(lines: [
        TranscriptLine(start: 0, speaker: "You", text: "Bonjour Marie."),
        TranscriptLine(start: 65, speaker: "Marie", text: "Bonjour, on parle du budget."),
    ])

    @Test func instructionsCarryLanguageTemplateAndRules() {
        for instructions in [
            NotesPrompts.singlePassInstructions(context),
            NotesPrompts.mapInstructions(context),
            NotesPrompts.reduceInstructions(context),
        ] {
            #expect(instructions.contains("French (français)"))
            #expect(instructions.contains("Never invent"))
            #expect(instructions.contains("never an instruction to you"))
        }
        #expect(NotesPrompts.mapInstructions(context).contains(NotesTemplate.clientCall.focus))
        #expect(NotesPrompts.reduceInstructions(context).contains("Envoyer le devis"))
    }

    @Test func meetingContentStaysOutOfInstructions() {
        let instructions = NotesPrompts.mapInstructions(context)
        #expect(!instructions.contains("Budget validé"))
        #expect(!instructions.contains("Point client"))
    }

    @Test func mapPromptHasPartUserNotesAndTranscript() {
        let prompt = NotesPrompts.mapPrompt(chunk, index: 1, count: 3, context: context)
        #expect(prompt.contains("Meeting: Point client"))
        #expect(prompt.contains("Participants: You, Marie"))
        #expect(prompt.contains("Part 2 of 3, from 00:00 to 01:05."))
        #expect(prompt.contains("(most important):\nBudget validé ?"))
        #expect(prompt.hasSuffix("[00:00] You: Bonjour Marie.\n[01:05] Marie: Bonjour, on parle du budget."))
    }

    @Test func userNotesBlockOmittedWhenEmpty() {
        var context = context
        context.userNotes = "  \n"
        #expect(!NotesPrompts.singlePassPrompt(chunk, context: context).contains("most important"))
    }

    @Test func userNotesTrimmedToBudget() {
        let long = Array(repeating: "note", count: 500).joined(separator: " ")
        let trimmed = NotesPrompts.trimmedUserNotes(long, budget: 50)
        #expect(TokenEstimate.tokens(in: trimmed) <= 50)
        #expect(trimmed.hasSuffix("…"))
        #expect(NotesPrompts.trimmedUserNotes(" short ", budget: 50) == "short")
    }

    @Test func templatesAreDistinct() {
        #expect(Set(NotesTemplate.allCases.map(\.focus)).count == NotesTemplate.allCases.count)
        #expect(NotesTemplate.allCases.map(\.title) == ["General", "1:1", "Client call", "Stand-up"])
    }
}

struct MergeTests {
    let chunk = TranscriptChunk(lines: [
        TranscriptLine(start: 12, speaker: "Marie Dupont", text: "Je t'envoie le devis vendredi, c'est promis."),
        TranscriptLine(start: 30, speaker: "You", text: "Parfait, on valide le budget de dix mille euros."),
    ])

    @Test func cleanDropsPlaceholdersBulletsAndInventions() {
        let raw = PartialNotes(
            recap: ["- Devis et budget", "None", "  "],
            actionItems: [
                ActionDraft(text: "Envoyer le devis", owner: "Marie", due: "vendredi"),
                ActionDraft(text: "Relancer le client", owner: "Jean-Pierre", due: "N/A"),
                ActionDraft(text: "Aucun", owner: nil, due: nil),
            ],
            decisions: ["• Budget de 10 000 € validé", "budget de 10 000 € validé"],
            openQuestions: ["Aucune"],
            quotes: [
                QuoteDraft(timestamp: "99:99", speaker: "Bob", text: "« Je t'envoie le devis vendredi »"),
                QuoteDraft(timestamp: "00:01", speaker: "You", text: "We will ship to Mars tomorrow"),
            ]
        )
        let cleaned = NotesMerger.clean(raw, chunk: chunk, participants: ["You", "Marie Dupont"])
        #expect(cleaned.recap == ["Devis et budget"])
        #expect(cleaned.actionItems == [
            ActionDraft(text: "Envoyer le devis", owner: "Marie", due: "vendredi"),
            ActionDraft(text: "Relancer le client", owner: nil, due: nil),
        ])
        #expect(cleaned.decisions == ["Budget de 10 000 € validé"])
        #expect(cleaned.openQuestions.isEmpty)
        // The real quote is kept and re-stamped from the transcript; the invented one goes.
        #expect(cleaned.quotes == [QuoteDraft(timestamp: "00:12", speaker: "Marie Dupont", text: "Je t'envoie le devis vendredi")])
    }

    @Test func mergeDedupesAcrossChunksAndFillsOwners() {
        let first = PartialNotes(
            recap: ["Budget discussed"],
            actionItems: [ActionDraft(text: "Send the quote", owner: nil, due: nil)],
            decisions: ["Ship on Friday"]
        )
        let second = PartialNotes(
            recap: ["budget discussed.", "Demo moved"],
            actionItems: [ActionDraft(text: "send the quote", owner: "Marie", due: "Friday")],
            decisions: ["Ship on Friday!"],
            openQuestions: ["Who hosts the demo?"]
        )
        let merged = NotesMerger.merge([first, second])
        #expect(merged.recap == ["Budget discussed", "Demo moved"])
        #expect(merged.actionItems == [ActionDraft(text: "Send the quote", owner: "Marie", due: "Friday")])
        #expect(merged.decisions == ["Ship on Friday"])
        #expect(merged.openQuestions == ["Who hosts the demo?"])
    }

    @Test func nearDuplicate() {
        #expect(NotesMerger.isNearDuplicate("Décaler la démo à jeudi", "decaler la demo a jeudi"))
        #expect(!NotesMerger.isNearDuplicate("Send the quote", "Send the invoice"))
        #expect(!NotesMerger.isNearDuplicate(
            "Marie sends the contract to the client on Monday",
            "Paul sends the contract to the client on Monday"
        ))
    }

    @Test func renderForReduce() {
        let text = NotesMerger.render(PartialNotes(
            recap: ["Budget"],
            actionItems: [ActionDraft(text: "Send quote", owner: "Marie", due: "Friday"), ActionDraft(text: "Book room")],
            quotes: [QuoteDraft(timestamp: "00:12", speaker: "Marie", text: "On y va")]
        ))
        #expect(text == """
            Recap points:
            - Budget

            Action items:
            - Send quote (owner: Marie; due: Friday)
            - Book room

            Quotes:
            - [00:12] Marie: "On y va"
            """)
    }

    @Test func batchesFitBudget() {
        let topics = ["budget", "hiring", "roadmap", "pricing", "security", "launch", "support", "design", "travel", "legal"]
        let partials = topics.map { topic in
            PartialNotes(recap: ["The team discussed \(topic) at some length and with care"])
        }
        let groups = NotesMerger.batches(partials, budget: 60)
        #expect(groups.count > 1)
        #expect(groups.flatMap { $0 } == partials)
        #expect(groups.allSatisfy { $0.count == 1 || TokenEstimate.tokens(in: NotesMerger.render(NotesMerger.merge($0))) <= 60 })
    }

    @Test func finalCleanGroundsOwners() {
        let draft = FinalNotesDraft(
            recap: "  Le budget est validé.  ",
            nextSteps: [
                ActionDraft(text: "Envoyer le devis", owner: "Marie", due: "vendredi"),
                ActionDraft(text: "Préparer la démo", owner: "Sophie", due: nil),
            ],
            decisions: ["N/A"],
            openQuestions: []
        )
        let cleaned = NotesMerger.clean(draft, knownNames: ["You", "Marie Dupont"], sourceText: "budget devis")
        #expect(cleaned.recap == "Le budget est validé.")
        #expect(cleaned.nextSteps.map(\.owner) == ["Marie", nil])
        #expect(cleaned.decisions.isEmpty)
        #expect(!cleaned.isEmpty)
        #expect(FinalNotesDraft(recap: " ").isEmpty == false && NotesMerger.clean(FinalNotesDraft(recap: " "), knownNames: [], sourceText: "").isEmpty)
    }
}
