import Foundation
import Testing

@testable import FluenceMeetingCore

/// FLU-132: a meeting channel transcribed by ElevenLabs, read and turned into the segments and
/// turns the local pipeline produces. Sample bodies follow ElevenLabs' API reference
/// (speech-to-text › convert): `words` with `type` word / spacing / audio_event, `start`,
/// `end`, `speaker_id`.
struct CloudTranscriptTests {
    private func words(_ json: String) throws -> [CloudTranscript.SpokenWord] {
        try #require(CloudTranscript.words(json: Data(json.utf8)))
    }

    private func word(_ text: String, _ start: Double, _ end: Double, _ speaker: String? = nil) -> String {
        let id = speaker.map { #","speaker_id":"\#($0)""# } ?? ""
        return #"{"text":"\#(text)","type":"word","start":\#(start),"end":\#(end),"logprob":-0.1\#(id)}"#
    }

    private func spacing(_ start: Double, _ end: Double, _ speaker: String? = nil) -> String {
        let id = speaker.map { #","speaker_id":"\#($0)""# } ?? ""
        return #"{"text":" ","type":"spacing","start":\#(start),"end":\#(end),"logprob":0\#(id)}"#
    }

    private func body(_ items: [String]) -> String {
        #"{"language_code":"fr","language_probability":0.98,"text":"…","words":[\#(items.joined(separator: ","))]}"#
    }

    // MARK: - Reading the answer

    @Test func theDocsSampleGivesOneTimedWordWithItsSpeaker() throws {
        let sample = #"{"language_code":"en","language_probability":0.98,"text":"Hello world!","words":[{"end":0.5,"logprob":-0.124,"speaker_id":"speaker_1","start":0,"text":"Hello","type":"word"}]}"#
        let read = try words(sample)
        #expect(read == [CloudTranscript.SpokenWord(word: Word(text: "Hello", start: 0, end: 0.5), speaker: "speaker_1")])
    }

    @Test func spacingAndSoundEventsAreLeftOut() throws {
        let read = try words(body([
            word("Bonjour", 0, 0.4, "speaker_0"),
            spacing(0.4, 0.5, "speaker_0"),
            #"{"text":"(rires)","type":"audio_event","start":0.5,"end":1.0,"logprob":0,"speaker_id":"speaker_0"}"#,
            word("à", 1.0, 1.1, "speaker_0"),
        ]))
        #expect(read.map(\.word.text) == ["Bonjour", "à"])
    }

    @Test func anEmptyAnswerHasNoWords() throws {
        #expect(try words(#"{"language_code":"fr","language_probability":0.5,"text":"","words":[]}"#).isEmpty)
    }

    @Test func aBodyThatIsNotATranscriptIsMalformed() {
        #expect(CloudTranscript.words(json: Data("<html>".utf8)) == nil)
        #expect(CloudTranscript.words(json: Data("{}".utf8)) == nil)
        #expect(CloudTranscript.words(json: Data(#"{"text":"x","words":"x"}"#.utf8)) == nil)
        // A multichannel answer (`transcripts`) is not what was asked.
        #expect(CloudTranscript.words(json: Data(#"{"transcripts":[]}"#.utf8)) == nil)
    }

    @Test func aWordWithoutTimingIsMalformedRatherThanDropped() {
        let untimed = body([#"{"text":"mot","type":"word","logprob":-0.1}"#])
        #expect(CloudTranscript.words(json: Data(untimed.utf8)) == nil)
        let noText = body([#"{"type":"word","start":0,"end":1,"logprob":-0.1}"#])
        #expect(CloudTranscript.words(json: Data(noText.utf8)) == nil)
    }

    // MARK: - Into the meeting model

    @Test func eachSpeakerChangeStartsASegmentAndATurn() throws {
        let read = try words(body([
            word("Bonjour", 0.0, 0.4, "speaker_0"), spacing(0.4, 0.45, "speaker_0"),
            word("à", 0.45, 0.5, "speaker_0"), spacing(0.5, 0.55, "speaker_0"),
            word("tous.", 0.55, 0.9, "speaker_0"),
            word("Salut", 1.0, 1.3, "speaker_1"),
            word("Oui", 1.5, 1.7, "speaker_0"),
        ]))
        let channel = CloudTranscript.channel(read, source: .system, speakerID: Speaker.othersID)
        #expect(channel.segments.map(\.text) == ["Bonjour à tous.", "Salut", "Oui"])
        #expect(channel.segments.allSatisfy { $0.source == .system && $0.speakerID == Speaker.othersID })
        #expect(channel.segments.map(\.words.count) == [3, 1, 1])
        let first = try #require(channel.segments.first)
        #expect(first.start == 0 && first.end == 0.9)
        #expect(channel.turns == [
            SpeakerTurn(speaker: "speaker_0", start: 0, end: 0.9),
            SpeakerTurn(speaker: "speaker_1", start: 1.0, end: 1.3),
            SpeakerTurn(speaker: "speaker_0", start: 1.5, end: 1.7),
        ])
    }

    @Test func aPauseOrTheLengthCapEndsASegmentLikeTheLocalCutter() throws {
        let limits = UtteranceSegmenter.Config()
        // A pause as long as the local cutter's silence ends an utterance.
        let paused = [
            CloudTranscript.SpokenWord(word: Word(text: "un", start: 0, end: 0.3), speaker: nil),
            CloudTranscript.SpokenWord(word: Word(text: "deux", start: 0.3 + limits.minSilence, end: 1.2), speaker: nil),
        ]
        #expect(CloudTranscript.channel(paused, source: .microphone, speakerID: Speaker.meID).segments.map(\.text) == ["un", "deux"])

        // 40 s of unbroken speech: no segment longer than the local cap.
        let flowing = (0..<100).map { i in
            CloudTranscript.SpokenWord(word: Word(text: "mot\(i)", start: Double(i) * 0.4, end: Double(i) * 0.4 + 0.4), speaker: nil)
        }
        let segments = CloudTranscript.channel(flowing, source: .microphone, speakerID: Speaker.meID).segments
        #expect(segments.count > 1)
        #expect(segments.allSatisfy { $0.end - $0.start <= limits.maxDuration })
        #expect(segments.flatMap(\.words).count == 100)
    }

    @Test func withoutDiarizationThereAreNoTurns() {
        let mic = [CloudTranscript.SpokenWord(word: Word(text: "moi", start: 0, end: 0.3), speaker: nil)]
        let channel = CloudTranscript.channel(mic, source: .microphone, speakerID: Speaker.meID)
        #expect(channel.turns.isEmpty)
        #expect(channel.segments.map(\.speakerID) == [Speaker.meID])
    }

    @Test func noWordsGiveNoSegments() {
        let channel = CloudTranscript.channel([], source: .system, speakerID: Speaker.othersID)
        #expect(channel.segments.isEmpty && channel.turns.isEmpty)
    }

    @Test func theDictionaryRunsOnEachSegmentsText() {
        let words = [CloudTranscript.SpokenWord(word: Word(text: "fluence", start: 0, end: 0.4), speaker: nil)]
        let channel = CloudTranscript.channel(words, source: .microphone, speakerID: Speaker.meID) { $0.capitalized }
        #expect(channel.segments.map(\.text) == ["Fluence"])
    }

    /// What the local pipeline does next runs unchanged: the turns attribute the system
    /// segments to `S1…Sn` by first appearance.
    @Test func theTurnsNameTheVoicesThroughTheExistingAttribution() throws {
        let read = try words(body([
            word("Bonjour", 0.0, 0.4, "speaker_3"),
            word("Salut", 1.0, 1.3, "speaker_0"),
            word("Oui", 1.5, 1.7, "speaker_3"),
        ]))
        let channel = CloudTranscript.channel(read, source: .system, speakerID: Speaker.othersID)
        let attribution = SpeakerAssignment.attribute(channel.segments, turns: channel.turns, fallbackID: Speaker.othersID)
        #expect(attribution.segments.map(\.speakerID) == ["S1", "S2", "S1"])
        #expect(attribution.labels == ["speaker_3": "S1", "speaker_0": "S2"])
    }
}
