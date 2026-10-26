import Foundation
import Testing

@testable import FluenceMeetingCore

/// Runs the contract in `meeting-test-vectors.json`, beside this file.
struct MeetingVectorTests {
    struct Vectors: Decodable {
        let version: Int
        let normalization: [NormalizationCase]
        let merge: [MergeCase]
        let wordSpeaker: [WordSpeakerCase]
        let attribution: [AttributionCase]
        let naming: [NamingCase]
    }

    struct NormalizationCase: Decodable {
        let name: String
        let input: String
        let tokens: [String]
    }

    struct VectorWord: Decodable {
        let text: String
        let start: Double
        let end: Double
        var word: Word { Word(text: text, start: start, end: end) }
    }

    struct VectorSegment: Decodable {
        let source: String
        let speakerID: String
        let start: Double
        let end: Double
        let text: String
        var words: [VectorWord]?

        var segment: TranscriptSegment {
            TranscriptSegment(
                source: AudioSource(rawValue: source)!,
                speakerID: speakerID,
                start: start,
                end: end,
                text: text,
                words: (words ?? []).map(\.word)
            )
        }
    }

    struct MergeCase: Decodable {
        struct Expected: Decodable {
            let source: String
            let start: Double
            let text: String
        }
        let name: String
        let mic: [VectorSegment]
        let system: [VectorSegment]
        let expected: [Expected]
    }

    struct WordSpeakerCase: Decodable {
        let name: String
        let turns: [SpeakerTurn]
        let words: [VectorWord]
        let expected: [String?]
    }

    struct AttributionCase: Decodable {
        struct Expected: Decodable {
            let speakerID: String
            let start: Double
            let end: Double
            let text: String
        }
        let name: String
        let fallbackID: String
        let turns: [SpeakerTurn]
        let segments: [VectorSegment]
        let expected: [Expected]
        let labels: [String: String]
    }

    struct NamingCase: Decodable {
        struct VectorSpeaker: Decodable, Equatable {
            let id: String
            var name: String?
            var nameSource: String?
        }
        let name: String
        let speakers: [VectorSpeaker]
        let windowParticipants: [String]
        /// FLU-33: the window's list looked complete. Absent means false.
        var windowComplete: Bool?
        let attendees: [String]
        let voicePrintSimilarity: [String: [String: Double]]
        let expected: [VectorSpeaker]
    }

    static func load() throws -> Vectors {
        let url = try #require(Bundle.module.url(forResource: "meeting-test-vectors", withExtension: "json"))
        return try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: url))
    }

    @Test("normalisation produces the contracted tokens")
    func normalization() throws {
        let vectors = try Self.load()
        #expect(vectors.version == 1)
        #expect(!vectors.normalization.isEmpty)
        for testCase in vectors.normalization {
            #expect(TextTokens.normalize(testCase.input) == testCase.tokens, "\(testCase.name)")
        }
    }

    @Test("merge keeps time order and drops mic echoes")
    func merge() throws {
        for testCase in try Self.load().merge {
            let merged = TranscriptMerger.merge(
                microphone: testCase.mic.map(\.segment),
                system: testCase.system.map(\.segment)
            )
            let actual = merged.map { "\($0.source.rawValue)@\($0.start): \($0.text)" }
            let expected = testCase.expected.map { "\($0.source)@\($0.start): \($0.text)" }
            #expect(actual == expected, "\(testCase.name)")
        }
    }

    @Test("each word goes to the contracted speaker")
    func wordSpeaker() throws {
        for testCase in try Self.load().wordSpeaker {
            let actual = SpeakerAssignment.speakers(for: testCase.words.map(\.word), turns: testCase.turns)
            #expect(actual == testCase.expected, "\(testCase.name)")
        }
    }

    @Test("segments are split and relabelled as contracted")
    func attribution() throws {
        for testCase in try Self.load().attribution {
            let result = SpeakerAssignment.attribute(
                testCase.segments.map(\.segment),
                turns: testCase.turns,
                fallbackID: testCase.fallbackID
            )
            let actual = result.segments.map { "\($0.speakerID) \($0.start)-\($0.end) \($0.text)" }
            let expected = testCase.expected.map { "\($0.speakerID) \($0.start)-\($0.end) \($0.text)" }
            #expect(actual == expected, "\(testCase.name)")
            #expect(result.labels == testCase.labels, "\(testCase.name)")
        }
    }

    @Test("speakers are named as contracted")
    func naming() throws {
        for testCase in try Self.load().naming {
            let speakers = testCase.speakers.map {
                Speaker(id: $0.id, name: $0.name, nameSource: $0.nameSource.flatMap(NameSource.init(rawValue:)))
            }
            let named = SpeakerNaming.name(speakers, candidates: .init(
                windowParticipants: testCase.windowParticipants,
                windowListComplete: testCase.windowComplete ?? false,
                attendees: testCase.attendees,
                voicePrintSimilarity: testCase.voicePrintSimilarity
            ))
            let actual = named.map {
                NamingCase.VectorSpeaker(id: $0.id, name: $0.name, nameSource: $0.nameSource?.rawValue)
            }
            #expect(actual == testCase.expected, "\(testCase.name)")
        }
    }
}
