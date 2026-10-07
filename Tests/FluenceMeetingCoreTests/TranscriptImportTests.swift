import Foundation
import Testing

@testable import FluenceMeetingCore

/// Runs the shared contract in `shared/transcript-import-vectors.json` (FLU-16); this copy
/// must stay byte-identical to the shared one (CI checks).
struct TranscriptImportVectorTests {
    struct Vectors: Decodable {
        let version: Int
        let parse: [ParseCase]
    }

    struct ParseCase: Decodable {
        let name: String
        let input: String
        let format: String
        let title: String?
        let turns: [VectorTurn]
    }

    struct VectorTurn: Decodable {
        let speaker: String?
        let start: Double?
        let end: Double?
        let text: String
    }

    static func load() throws -> Vectors {
        let url = try #require(Bundle.module.url(forResource: "transcript-import-vectors", withExtension: "json"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    private static func same(_ a: Double?, _ b: Double?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a - b) < 1e-6
        default: false
        }
    }

    @Test("every file shape produces the contracted turns")
    func parse() throws {
        let vectors = try Self.load()
        #expect(vectors.version == 1)
        #expect(!vectors.parse.isEmpty)
        for testCase in vectors.parse {
            let result = TranscriptImport.parse(testCase.input)
            #expect(result.format.rawValue == testCase.format, "\(testCase.name)")
            #expect(result.title == testCase.title, "\(testCase.name)")
            #expect(result.turns.count == testCase.turns.count, "\(testCase.name): \(result.turns)")
            for (turn, expected) in zip(result.turns, testCase.turns) {
                #expect(turn.speaker == expected.speaker, "\(testCase.name)")
                #expect(turn.text == expected.text, "\(testCase.name)")
                #expect(Self.same(turn.start, expected.start), "\(testCase.name): start \(String(describing: turn.start))")
                #expect(Self.same(turn.end, expected.end), "\(testCase.name): end \(String(describing: turn.end))")
            }
        }
    }
}

struct TranscriptImportMeetingTests {
    let start = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("the user becomes me on the mic; others keep their names, numbered in order")
    func speakers() {
        let transcript = TranscriptImport.parse("[00:05] Alice: Salut.\n[00:09] Clément: Salut Alice.\n[00:12] Bob: Bonjour.\n")
        let meeting = TranscriptImport.meeting(from: transcript, title: "Point", startedAt: start, me: "Clément", sourceName: "point.txt")

        #expect(meeting.trigger == .imported)
        #expect(meeting.importedFrom == "point.txt")
        #expect(meeting.speakers.map(\.id) == ["me", "S1", "S2"])
        #expect(meeting.speakers.map(\.name) == ["Clément", "Alice", "Bob"])
        let sources = Set(meeting.speakers.map(\.nameSource))
        #expect(sources == [.user])
        #expect(meeting.segments.map(\.speakerID) == ["S1", "me", "S2"])
        #expect(meeting.segments.map(\.source) == [.system, .microphone, .system])
        #expect(!meeting.segments.map(\.isFinal).contains(false))
        // A turn ends where the next one starts; the last one lasts its estimated length.
        #expect(meeting.segments.map(\.end) == [9, 12, 13])
        #expect(meeting.endedAt == start.addingTimeInterval(13))
        #expect(MeetingSummary(meeting).isImported == true)
    }

    @Test("without the user among the speakers there is no 'me'; text before any name is one unnamed voice, text after a name stays with it")
    func noMe() {
        let transcript = TranscriptImport.parse("Bonjour à tous.\n\nAlice: On commence.\n\nMerci.\n")
        let meeting = TranscriptImport.meeting(from: transcript, title: "Notes", startedAt: start, me: nil)

        #expect(!meeting.speakers.contains { $0.isMe })
        #expect(meeting.speakers.map(\.id) == ["S1", "S2"])
        #expect(meeting.speakers.map(\.name) == ["Alice", nil])
        #expect(meeting.segments.map(\.speakerID) == ["S2", "S1", "S1"])
    }

    @Test("untimed turns follow each other at 150 words a minute")
    func estimatedTimes() {
        let transcript = TranscriptImport.parse("Alice: un deux trois quatre cinq.\nBob: oui.\n")
        let meeting = TranscriptImport.meeting(from: transcript, title: "T", startedAt: start, me: nil)

        #expect(meeting.segments.map(\.start) == [0, 2])
        #expect(meeting.segments.map(\.end) == [2, 3])
        #expect(meeting.duration == 3)
    }

    @Test("out-of-order cues are sorted by time")
    func sorted() {
        let transcript = ImportedTranscript(format: .text, turns: [
            .init(speaker: "A", start: 10, end: 11, text: "deux"),
            .init(speaker: "B", start: 2, end: 3, text: "un"),
        ])
        let meeting = TranscriptImport.meeting(from: transcript, title: "T", startedAt: start, me: nil)
        #expect(meeting.segments.map(\.text) == ["un", "deux"])
    }

    @Test("the user is found by full name, or by a first name only one speaker has")
    func guessMe() {
        let names = ["Alice Martin", "Clément V.", "Bob"]
        #expect(TranscriptImport.guessMe(in: names, userNames: ["Clement Veniard"]) == "Clément V.")
        #expect(TranscriptImport.guessMe(in: ["clément veniard", "Bob"], userNames: ["Clément Veniard"]) == "clément veniard")
        #expect(TranscriptImport.guessMe(in: ["Clément A", "Clément B"], userNames: ["Clément Veniard"]) == nil)
        #expect(TranscriptImport.guessMe(in: names, userNames: []) == nil)
    }
}
