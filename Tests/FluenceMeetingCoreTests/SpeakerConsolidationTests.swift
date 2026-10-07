import Foundation
import Testing

@testable import FluenceMeetingCore

/// FLU-22: `shared/speaker-consolidation-vectors.json`.
struct SpeakerConsolidationVectorTests {
    struct Vectors: Decodable {
        var consolidate: [Case]
        var speakerCap: [CapCase]
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
