import FluenceCore
import FluenceDictionary
import FluenceMeetingCore
import Foundation
import Testing
@testable import FluenceImport

/// FLU-144: what an import adds, on small synthetic data (never anyone's real files).
@Suite struct ImportPlannerTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let day: TimeInterval = 86_400
    var all: Set<ImportChoice> {
        Set(ImportApp.allCases.flatMap { app in ImportKind.allCases.map { ImportChoice(app, $0) } })
    }

    func dictation(_ name: String, daysAgo: Double, offset: TimeInterval = 0) -> ForeignDictation {
        ForeignDictation(id: StableID.uuid(name), date: now.addingTimeInterval(-daysAgo * day + offset), text: "texte \(name)", seconds: 3)
    }

    func plan(_ sources: [ForeignData], retention: HistoryRetention = .month, selection: Set<ImportChoice>? = nil, existing: ImportExisting = ImportExisting()) -> ImportPlan {
        ImportPlanner.plan(sources, selection: selection ?? all, retention: retention, now: now, existing: existing, userNames: [])
    }

    // MARK: Retention (decision 2A)

    @Test func dictationsOlderThanTheHistoryAreLeftAsideAndCounted() {
        var wispr = ForeignData(app: .wisprFlow)
        wispr.dictations = [dictation("a", daysAgo: 1), dictation("b", daysAgo: 29), dictation("c", daysAgo: 31), dictation("d", daysAgo: 400)]
        let result = plan([wispr])
        #expect(result.dictations.map(\.dictation.id) == [StableID.uuid("a"), StableID.uuid("b")])
        #expect(result.tally(.wisprFlow, .dictations) == ImportTally(toImport: 2, leftAside: 2))
        // Their real date is kept.
        #expect(result.dictations.first?.dictation.date == now.addingTimeInterval(-day))
    }

    @Test func oneDayKeepsOnlyTheLastDay() {
        var wispr = ForeignData(app: .wisprFlow)
        wispr.dictations = [dictation("a", daysAgo: 0.5), dictation("b", daysAgo: 2)]
        #expect(plan([wispr], retention: .day).tally(.wisprFlow, .dictations) == ImportTally(toImport: 1, leftAside: 1))
    }

    @Test func alwaysImportsEveryDictation() {
        var wispr = ForeignData(app: .wisprFlow)
        wispr.dictations = [dictation("a", daysAgo: 1), dictation("d", daysAgo: 4_000)]
        let result = plan([wispr], retention: .forever)
        #expect(result.dictations.count == 2)
        #expect(result.tally(.wisprFlow, .dictations).leftAside == 0)
    }

    @Test func dontKeepOffersNoDictations() {
        var wispr = ForeignData(app: .wisprFlow)
        wispr.dictations = [dictation("a", daysAgo: 0)]
        let result = plan([wispr], retention: .never)
        #expect(!ImportPlanner.offersDictations(.never))
        #expect(result.dictations.isEmpty)
        #expect(result.tally(.wisprFlow, .dictations) == ImportTally())
    }

    // MARK: No duplicates

    @Test func aSecondImportAddsNothing() {
        var wispr = ForeignData(app: .wisprFlow)
        wispr.entries = [.term("Ollivault"), .correction(hear: "nova tec", write: "Novatek")]
        wispr.snippets = [Snippet(id: StableID.uuid("wisprflow:snippet:1"), trigger: "mon adresse", expansion: "1 rue de la Paix")]
        wispr.dictations = [dictation("a", daysAgo: 1)]
        wispr.meetings = [ForeignMeeting(id: StableID.uuid("wisprflow:meeting:1"), title: "Point hebdo", startedAt: now, userNotes: "notes")]
        let first = plan([wispr])
        #expect(first.entries.count == 2 && first.snippets.count == 1 && first.dictations.count == 1 && first.meetings.count == 1)

        let existing = ImportExisting(
            entries: first.entries, snippets: first.snippets,
            dictations: first.dictations.map { ($0.dictation.id, $0.dictation.date) },
            meetings: first.meetings.map { ($0.id, $0.title, $0.startedAt) }
        )
        let second = plan([wispr], existing: existing)
        #expect(second.isEmpty)
        #expect(second.tally(.wisprFlow, .dictionary) == ImportTally(duplicates: 3))
        #expect(second.tally(.wisprFlow, .dictations) == ImportTally(duplicates: 1))
        #expect(second.tally(.wisprFlow, .meetings) == ImportTally(duplicates: 1))
    }

    @Test func dictionaryEntriesMatchTheUsersOwnIgnoringCase() {
        var wispr = ForeignData(app: .wisprFlow)
        wispr.entries = [.term("ollivault"), .term("Brumeware"), .term("brumeware")]
        let result = plan([wispr], existing: ImportExisting(entries: [.term("Ollivault")]))
        #expect(result.entries.map(\.write) == ["Brumeware"])
        #expect(result.tally(.wisprFlow, .dictionary) == ImportTally(toImport: 1, duplicates: 2))
    }

    @Test func aSnippetWhoseTriggerExistsIsLeftOut() {
        var wispr = ForeignData(app: .wisprFlow)
        wispr.snippets = [Snippet(id: UUID(), trigger: "Mon adresse", expansion: "ailleurs")]
        let result = plan([wispr], existing: ImportExisting(snippets: [Snippet(trigger: "mon adresse", expansion: "ici")]))
        #expect(result.snippets.isEmpty)
    }

    /// superwhisper imports Wispr Flow's dictations: its copies, stamped the same second,
    /// are not imported twice — and not counted as left aside either.
    @Test func anotherAppsCopyOfADictationIsADuplicate() {
        var wispr = ForeignData(app: .wisprFlow)
        wispr.dictations = [dictation("w1", daysAgo: 1), dictation("w2", daysAgo: 90)]
        var superwhisper = ForeignData(app: .superwhisper)
        superwhisper.dictations = [
            dictation("s1", daysAgo: 1, offset: 0.4), dictation("s2", daysAgo: 90, offset: -0.6), dictation("s3", daysAgo: 2),
        ]
        let result = plan([wispr, superwhisper])
        #expect(result.dictations.map(\.dictation.id) == [StableID.uuid("w1"), StableID.uuid("s3")])
        #expect(result.tally(.superwhisper, .dictations) == ImportTally(toImport: 1, duplicates: 2))

        // Wispr Flow unticked: superwhisper's copies are the only ones, so they come in.
        let alone = plan([wispr, superwhisper], selection: all.subtracting([ImportChoice(.wisprFlow, .dictations)]))
        #expect(alone.dictations.map(\.dictation.id) == [StableID.uuid("s1"), StableID.uuid("s3")])
    }

    @Test func aDictationFluenceAlreadyHasAtThatSecondIsADuplicate() {
        var wispr = ForeignData(app: .wisprFlow)
        wispr.dictations = [dictation("a", daysAgo: 1)]
        let result = plan([wispr], existing: ImportExisting(dictations: [(UUID(), now.addingTimeInterval(-day + 0.5))]))
        #expect(result.dictations.isEmpty)
    }

    @Test func aMeetingAnotherAppAlreadyGaveIsADuplicate() {
        var wispr = ForeignData(app: .wisprFlow)
        wispr.meetings = [ForeignMeeting(id: UUID(), title: "Point hebdo", startedAt: now)]
        var granola = ForeignData(app: .granola)
        granola.meetings = [
            ForeignMeeting(id: UUID(), title: "point  Hébdo", startedAt: now.addingTimeInterval(60)),
            ForeignMeeting(id: UUID(), title: "Point hebdo", startedAt: now.addingTimeInterval(7 * day)),
        ]
        let result = plan([wispr, granola])
        #expect(result.meetings.count == 2)
        #expect(result.tally(.granola, .meetings) == ImportTally(toImport: 1, duplicates: 1))
    }

    @Test func untickedBoxesAreCountedButNotImported() {
        var wispr = ForeignData(app: .wisprFlow)
        wispr.entries = [.term("Ollivault")]
        wispr.dictations = [dictation("a", daysAgo: 1)]
        let result = plan([wispr], selection: [ImportChoice(.wisprFlow, .dictations)])
        #expect(result.entries.isEmpty)
        #expect(result.tally(.wisprFlow, .dictionary).toImport == 1)
        #expect(result.dictations.count == 1)
    }

    // MARK: Mapping into Fluence

    @Test func aMeetingBecomesAnImportedMeetingWithItsSourceAndNotes() throws {
        var wispr = ForeignData(app: .wisprFlow)
        let transcript = ImportedTranscript(format: .text, turns: [
            .init(speaker: "Alice Martin", start: 0, text: "Bonjour."),
            .init(speaker: Placeholder.voice("2"), start: 4, text: "Salut."),
        ])
        wispr.meetings = [
            ForeignMeeting(id: StableID.uuid("m"), title: "", startedAt: now, endedAt: now.addingTimeInterval(600),
                           transcript: transcript, userNotes: "à faire", summary: "Résumé."),
            ForeignMeeting(id: StableID.uuid("n"), title: "Idées", startedAt: now, userNotes: "une note", isNote: true),
        ]
        let result = plan([wispr])
        let meeting = try #require(result.meetings.first)
        #expect(meeting.id == StableID.uuid("m"))
        #expect(meeting.trigger == .imported)
        #expect(meeting.importedFrom == "Wispr Flow")
        #expect(meeting.importedAt != nil)
        #expect(meeting.title == "Réunion importée")
        #expect(meeting.endedAt == now.addingTimeInterval(600))
        #expect(meeting.userNotes == "à faire")
        #expect(meeting.notes?.recap == "Résumé.")
        #expect(meeting.segments.map(\.text) == ["Bonjour.", "Salut."])
        // A voice with no name reads « Intervenant N », not the reader's label.
        #expect(meeting.speakers.map(\.name) == ["Alice Martin", nil])
        #expect(result.meetings.last?.segments.isEmpty == true)
        #expect(result.tally(.wisprFlow, .meetings) == ImportTally(toImport: 2, notes: 1))
    }

    @Test func stableIDsAreStable() {
        #expect(StableID.uuid("wisprflow:dictation:1") == StableID.uuid("wisprflow:dictation:1"))
        #expect(StableID.uuid("wisprflow:dictation:1") != StableID.uuid("wisprflow:dictation:2"))
    }
}
