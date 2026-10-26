import Foundation
import Testing

@testable import FluenceMeetingCore

/// FLU-22: `speaker-consolidation-vectors.json`, beside this file.
struct SpeakerConsolidationVectorTests {
    struct Vectors: Decodable {
        var consolidate: [Case]
        var speakerCap: [CapCase]
        var roster: [RosterCase]
        var windowNames: [WindowNamesCase]
    }

    /// FLU-33: when the call window's list gives a count.
    struct RosterCase: Decodable {
        var name: String
        var reads: [ParticipantRead]
        var trustedCount: Int?
    }

    /// FLU-33: the window's names through the cap, the consolidation and the naming.
    struct WindowNamesCase: Decodable {
        var name: String
        var reads: [ParticipantRead]
        var attendees: Int
        var turns: [SpeakerTurn]
        var embeddings: [String: [Float]]
        var cap: Int?
        var voices: Int
        var names: [String: String]
    }

    struct Case: Decodable {
        var name: String
        var turns: [SpeakerTurn]
        var embeddings: [String: [Float]]
        var cap: Int?
        var mapping: [String: String]
    }

    struct CapCase: Decodable {
        var name: String
        var windowParticipants: Int
        var attendees: Int
        var cap: Int?
    }

    static let vectors: Vectors = {
        let url = Bundle.module.url(forResource: "speaker-consolidation-vectors", withExtension: "json")!
        return try! JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }()

    @Test("voices merge, absorb and fit the cap as contracted", arguments: vectors.consolidate.map(\.name))
    func consolidate(_ name: String) {
        let testCase = Self.vectors.consolidate.first { $0.name == name }!
        let result = SpeakerConsolidation.consolidate(turns: testCase.turns, embeddings: testCase.embeddings, cap: testCase.cap)
        #expect(result.mapping == testCase.mapping)
        let speakers = result.turns.map(\.speaker)
        let expected = testCase.turns.map { testCase.mapping[$0.speaker]! }
        #expect(speakers == expected)
    }

    @Test("the speaker cap comes from the call window and the calendar", arguments: vectors.speakerCap.map(\.name))
    func cap(_ name: String) {
        let testCase = Self.vectors.speakerCap.first { $0.name == name }!
        #expect(SpeakerConsolidation.speakerCap(windowParticipants: testCase.windowParticipants, attendees: testCase.attendees) == testCase.cap)
    }

    @Test("the call window gives a count only when its list looks complete", arguments: vectors.roster.map(\.name))
    func roster(_ name: String) {
        let testCase = Self.vectors.roster.first { $0.name == name }!
        #expect(ParticipantRoster(reads: testCase.reads).trustedCount == testCase.trustedCount)
    }

    @Test("a partial participant list never folds distinct voices into its names", arguments: vectors.windowNames.map(\.name))
    func windowNames(_ name: String) {
        let testCase = Self.vectors.windowNames.first { $0.name == name }!
        let roster = ParticipantRoster(reads: testCase.reads)
        let cap = SpeakerConsolidation.speakerCap(roster: roster, attendees: testCase.attendees)
        #expect(cap == testCase.cap)

        let result = SpeakerConsolidation.consolidate(turns: testCase.turns, embeddings: testCase.embeddings, cap: cap)
        var voices: [String] = []
        for turn in result.turns where !voices.contains(turn.speaker) { voices.append(turn.speaker) }
        #expect(voices.count == testCase.voices)

        let named = SpeakerNaming.name([.me()] + voices.map { Speaker(id: $0) }, candidates: .init(
            windowParticipants: roster.names,
            windowListComplete: roster.isComplete
        ))
        let names = Dictionary(uniqueKeysWithValues: named.compactMap { speaker in speaker.name.map { (speaker.id, $0) } })
        #expect(names == testCase.names)
    }

    @Test("the diarizer is never held below two voices")
    func diarizerCeiling() {
        #expect(SpeakerConsolidation.diarizerCeiling(cap: nil) == nil)
        #expect(SpeakerConsolidation.diarizerCeiling(cap: 1) == 2)
        #expect(SpeakerConsolidation.diarizerCeiling(cap: 2) == 2)
        #expect(SpeakerConsolidation.diarizerCeiling(cap: 5) == 5)
    }

    @Test("an over-split meeting comes back to its real speakers")
    func overSplitMeeting() {
        // Three people; the diarizer made seven voices of them: two splits each, plus a cough.
        var turns: [SpeakerTurn] = []
        let voices: [(String, [Float], TimeInterval)] = [
            ("P1a", [1, 0, 0], 300), ("P1b", [0.92, 0.2, 0.1], 120),
            ("P2a", [0, 1, 0], 250), ("P2b", [0.15, 0.9, 0.1], 90),
            ("P3a", [0, 0, 1], 200), ("P3b", [0.1, 0.15, 0.95], 60),
            ("cough", [0.5, 0.5, 0.5], 1.5),
        ]
        var clock: TimeInterval = 0
        for (id, _, seconds) in voices {
            turns.append(SpeakerTurn(speaker: id, start: clock, end: clock + seconds))
            clock += seconds
        }
        let embeddings = Dictionary(uniqueKeysWithValues: voices.map { ($0.0, $0.1) })
        let result = SpeakerConsolidation.consolidate(turns: turns, embeddings: embeddings, cap: nil)
        #expect(Set(result.mapping.values) == ["P1a", "P2a", "P3a"])
        #expect(result.mapping["P1b"] == "P1a")
        #expect(result.mapping["P2b"] == "P2a")
        #expect(result.mapping["P3b"] == "P3a")
    }
}
