import Foundation

/// One diarizer turn: "this voice was active over this span" (meeting time, seconds).
public struct SpeakerTurn: Codable, Sendable, Hashable {
    public var speaker: String
    public var start: TimeInterval
    public var end: TimeInterval

    public init(speaker: String, start: TimeInterval, end: TimeInterval) {
        self.speaker = speaker
        self.start = start
        self.end = end
    }
}

/// Attributes the system channel's words to diarized voices, splits segments where the
/// voice changes, and relabels the voices `S1…Sn` in order of first appearance.
///
/// Cross-platform contract: shared/meeting-test-vectors.json, `wordSpeaker` and
/// `attribution`.
///
/// **Word → speaker.** For a span [s, e], each turn's overlap is
/// `max(0, min(e, turn.end) − max(s, turn.start))`.
/// - The turn with the largest positive overlap wins; ties go to the earlier turn start,
///   then to the smaller speaker label (ordinal string comparison).
/// - With no positive overlap (including zero-length words), the nearest turn wins when
///   its gap `max(turn.start − e, s − turn.end, 0)` is at most 1.0 s; ties as above.
/// - Otherwise the word is unattributed (`nil`).
public enum SpeakerAssignment {
    public static let maxGap: TimeInterval = 1.0

    public static func speaker(
        start: TimeInterval,
        end: TimeInterval,
        turns: [SpeakerTurn]
    ) -> String? {
        var best: (turn: SpeakerTurn, overlap: Double)?
        for turn in turns {
            let overlap = max(0, min(end, turn.end) - max(start, turn.start))
            guard overlap > 0 else { continue }
            if let current = best {
                if overlap > current.overlap || (overlap == current.overlap && precedes(turn, current.turn)) {
                    best = (turn, overlap)
                }
            } else {
                best = (turn, overlap)
            }
        }
        if let best { return best.turn.speaker }

        var nearest: (turn: SpeakerTurn, gap: Double)?
        for turn in turns {
            let gap = max(turn.start - end, start - turn.end, 0)
            guard gap <= maxGap else { continue }
            if let current = nearest {
                if gap < current.gap || (gap == current.gap && precedes(turn, current.turn)) {
                    nearest = (turn, gap)
                }
            } else {
                nearest = (turn, gap)
            }
        }
        return nearest?.turn.speaker
    }

    /// One label per word, in order.
    public static func speakers(for words: [Word], turns: [SpeakerTurn]) -> [String?] {
        words.map { speaker(start: $0.start, end: $0.end, turns: turns) }
    }

    private static func precedes(_ a: SpeakerTurn, _ b: SpeakerTurn) -> Bool {
        if a.start != b.start { return a.start < b.start }
        return a.speaker < b.speaker
    }

    // MARK: - Segment attribution

    public struct Result: Sendable {
        /// The system segments, split at voice changes, labelled `S1…Sn` (or `fallbackID`).
        public var segments: [TranscriptSegment]
        /// Diarizer label → `S1…Sn`, for the voices that ended up with at least one segment.
        public var labels: [String: String]
    }

    /// Attributes every system segment.
    ///
    /// - Within a segment, an unattributed word takes the speaker of the closest preceding
    ///   attributed word, or — at the start — of the first following one.
    /// - A segment with no attributed word at all (or no words) is attributed as one span
    ///   with the same rule; failing that it gets `fallbackID`.
    /// - Consecutive words with the same speaker form one output segment. A segment that
    ///   stays whole keeps its text, span and id; a split piece gets the words' span and
    ///   `transform(words joined by single spaces)` as its text.
    /// - Output is time-ordered (`TranscriptMerger.sorted`), then labels are renamed
    ///   `S1, S2…` in order of first appearance. `fallbackID` is never renamed.
    public static func attribute(
        _ segments: [TranscriptSegment],
        turns: [SpeakerTurn],
        fallbackID: String,
        transform: (String) -> String = { $0 }
    ) -> Result {
        var pieces: [TranscriptSegment] = []

        for segment in segments {
            let labels = speakers(for: segment.words, turns: turns)
            let filled = fillGaps(labels)

            guard !segment.words.isEmpty, let first = filled.first, let firstLabel = first else {
                var whole = segment
                whole.speakerID = speaker(start: segment.start, end: segment.end, turns: turns) ?? fallbackID
                pieces.append(whole)
                continue
            }

            // Runs of identical labels.
            var runs: [(label: String, range: Range<Int>)] = []
            var runStart = 0
            var runLabel = firstLabel
            for index in filled.indices.dropFirst() {
                let label = filled[index] ?? runLabel
                if label != runLabel {
                    runs.append((runLabel, runStart..<index))
                    runStart = index
                    runLabel = label
                }
            }
            runs.append((runLabel, runStart..<filled.count))

            if runs.count == 1 {
                var whole = segment
                whole.speakerID = runLabel
                pieces.append(whole)
                continue
            }

            for run in runs {
                let words = Array(segment.words[run.range])
                pieces.append(TranscriptSegment(
                    source: segment.source,
                    speakerID: run.label,
                    start: words.first!.start,
                    end: words.last!.end,
                    text: transform(words.map(\.text).joined(separator: " ")),
                    words: words,
                    isFinal: segment.isFinal
                ))
            }
        }

        let ordered = TranscriptMerger.sorted(pieces)
        var mapping: [String: String] = [:]
        var next = 1
        for segment in ordered where segment.speakerID != fallbackID && mapping[segment.speakerID] == nil {
            mapping[segment.speakerID] = "S\(next)"
            next += 1
        }
        let relabelled = ordered.map { segment -> TranscriptSegment in
            var copy = segment
            copy.speakerID = mapping[segment.speakerID] ?? segment.speakerID
            return copy
        }
        return Result(segments: relabelled, labels: mapping)
    }

    /// Unattributed entries take the previous label, or the next one at the start.
    static func fillGaps(_ labels: [String?]) -> [String?] {
        guard let firstKnown = labels.first(where: { $0 != nil }) ?? nil else { return labels }
        var result: [String?] = []
        var last: String = firstKnown
        for label in labels {
            if let label { last = label }
            result.append(last)
        }
        return result
    }
}
