import Foundation

/// FLU-132: one channel of a finished meeting transcribed by ElevenLabs Scribe (Précis mode),
/// turned into what the local pipeline produces: segments cut where `UtteranceSegmenter`
/// would cut them (a pause, the length cap) and, on the diarized system channel, one
/// `SpeakerTurn` per segment. Attribution (`SpeakerAssignment`), consolidation, echo dedupe
/// (`TranscriptMerger`), naming and notes then run unchanged.
public enum CloudTranscript {
    public struct SpokenWord: Sendable, Equatable {
        public var word: Word
        /// The provider's voice (`speaker_0`…); nil without diarization.
        public var speaker: String?

        public init(word: Word, speaker: String?) {
            self.word = word
            self.speaker = speaker
        }
    }

    /// The words of an answer, in order, spacing and sound events left out. Nil when the body
    /// is not a transcript, or a word has no text or timing: the meeting then falls back to
    /// the Mac rather than lose words.
    public static func words(json: Data) -> [SpokenWord]? {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let items = object["words"] as? [[String: Any]]
        else { return nil }
        var words: [SpokenWord] = []
        for item in items {
            guard let text = item["text"] as? String else { return nil }
            guard item["type"] as? String == "word" else { continue }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let start = item["start"] as? Double, let end = item["end"] as? Double else { return nil }
            words.append(SpokenWord(word: Word(text: trimmed, start: start, end: max(start, end)), speaker: item["speaker_id"] as? String))
        }
        return words
    }

    /// The channel's segments, all `speakerID` (`Speaker.othersID` for the system channel, as
    /// the live pass leaves it, `Speaker.meID` for the mic), and the provider's voices as turns.
    /// - Parameter transform: the dictionary, run on each segment's text as the local pass does.
    public static func channel(
        _ words: [SpokenWord],
        source: AudioSource,
        speakerID: String,
        transform: (String) -> String = { $0 }
    ) -> (segments: [TranscriptSegment], turns: [SpeakerTurn]) {
        let limits = UtteranceSegmenter.Config()
        var segments: [TranscriptSegment] = []
        var turns: [SpeakerTurn] = []
        var run: [SpokenWord] = []

        func close() {
            guard let first = run.first?.word, let last = run.last?.word else { return }
            let words = run.map(\.word)
            segments.append(TranscriptSegment(
                source: source, speakerID: speakerID, start: first.start, end: last.end,
                text: transform(words.map(\.text).joined(separator: " ")), words: words
            ))
            if let speaker = run[0].speaker {
                turns.append(SpeakerTurn(speaker: speaker, start: first.start, end: last.end))
            }
            run = []
        }

        for spoken in words {
            if let first = run.first, let last = run.last,
               spoken.speaker != first.speaker
                || spoken.word.start - last.word.end >= limits.minSilence
                || spoken.word.end - first.word.start > limits.maxDuration {
                close()
            }
            run.append(spoken)
        }
        close()
        return (segments, turns)
    }
}
