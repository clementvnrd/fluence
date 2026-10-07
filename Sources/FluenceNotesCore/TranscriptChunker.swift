import Foundation

/// A slice of the transcript small enough for one model call.
public struct TranscriptChunk: Sendable, Hashable {
    public var lines: [TranscriptLine]

    public init(lines: [TranscriptLine]) {
        self.lines = lines
    }

    /// The chunk as the model reads it, one `[mm:ss] Name: text` line per utterance.
    public var text: String {
        lines.map(\.rendered).joined(separator: "\n")
    }

    public var startTime: TimeInterval { lines.first?.start ?? 0 }
    public var endTime: TimeInterval { lines.last?.start ?? 0 }
}

/// Cuts a transcript into chunks for the map step.
///
/// Cuts fall **between speaker turns** (a run of consecutive lines from one speaker), so a
/// chunk never ends mid-answer and the next one never opens on a reply with no question.
/// Only a single turn too long for a whole chunk is split, between its lines, and only a
/// single line too long for a chunk is split, between its sentences, then its words.
public enum TranscriptChunker {
    public static func chunk(
        _ lines: [TranscriptLine],
        budget: Int,
        measure: (String) -> Int = TokenEstimate.tokens
    ) -> [TranscriptChunk] {
        let budget = max(1, budget)
        let lines = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !lines.isEmpty else { return [] }

        // A unit is the smallest thing we refuse to cut: a whole turn when it fits, else a
        // line, else a piece of a line.
        var units: [[TranscriptLine]] = []
        for turn in turns(lines) {
            if cost(turn, measure) <= budget {
                units.append(turn)
                continue
            }
            for line in turn {
                if cost([line], measure) <= budget {
                    units.append([line])
                } else {
                    units.append(contentsOf: split(line, budget: budget, measure: measure).map { [$0] })
                }
            }
        }

        let costs = units.map { cost($0, measure) }
        let greedy = pack(costs, budget: budget)
        guard greedy.count > 1 else { return materialize(greedy, units) }

        // Even the chunks out: greedy packing leaves a full chunk followed by a scrap, and a
        // scrap gives the map step too little context to judge what matters. Re-pack at the
        // average size (plus slack for unit granularity); keep it only if it costs no extra call.
        let total = costs.reduce(0, +)
        let slack = costs.max() ?? 0
        let target = min(budget, (total + greedy.count - 1) / greedy.count + slack / 2)
        let balanced = pack(costs, budget: target)
        return materialize(balanced.count == greedy.count ? balanced : greedy, units)
    }

    // MARK: - Steps

    /// Consecutive lines from the same speaker.
    static func turns(_ lines: [TranscriptLine]) -> [[TranscriptLine]] {
        var turns: [[TranscriptLine]] = []
        for line in lines {
            if let last = turns.last?.last, last.speaker == line.speaker {
                turns[turns.count - 1].append(line)
            } else {
                turns.append([line])
            }
        }
        return turns
    }

    /// Cost of lines as they will be rendered, newline included.
    static func cost(_ lines: [TranscriptLine], _ measure: (String) -> Int) -> Int {
        lines.reduce(0) { $0 + measure($1.rendered) + 1 }
    }

    /// Greedy packing of unit costs into groups no larger than `budget`; returns the index
    /// ranges. A unit larger than the budget on its own still gets a group of its own.
    private static func pack(_ costs: [Int], budget: Int) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        var start = 0
        var running = 0
        for (index, cost) in costs.enumerated() {
            if running > 0 && running + cost > budget {
                groups.append(start..<index)
                start = index
                running = 0
            }
            running += cost
        }
        groups.append(start..<costs.count)
        return groups
    }

    private static func materialize(_ groups: [Range<Int>], _ units: [[TranscriptLine]]) -> [TranscriptChunk] {
        groups.map { range in TranscriptChunk(lines: units[range].flatMap { $0 }) }
    }

    /// Splits one over-long line into pieces that each fit, at sentence ends when possible,
    /// otherwise between words. Every piece keeps the line's speaker and start time.
    static func split(_ line: TranscriptLine, budget: Int, measure: (String) -> Int) -> [TranscriptLine] {
        let prefixCost = measure(TranscriptLine(start: line.start, speaker: line.speaker, text: "").rendered) + 1
        let room = max(1, budget - prefixCost)

        var pieces: [String] = []
        var current = ""
        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { pieces.append(trimmed) }
            current = ""
        }
        for sentence in sentences(line.text) {
            if measure(current + sentence) <= room {
                current += sentence
                continue
            }
            flush()
            if measure(sentence) <= room {
                current = sentence
                continue
            }
            // A "sentence" with no end in sight: fall back to words.
            for word in sentence.split(separator: " ", omittingEmptySubsequences: true) {
                let candidate = current.isEmpty ? String(word) : current + " " + word
                if measure(candidate) <= room || current.isEmpty {
                    current = candidate
                } else {
                    flush()
                    current = String(word)
                }
            }
            flush()
        }
        flush()
        return pieces.map { TranscriptLine(start: line.start, speaker: line.speaker, text: $0) }
    }

    /// Sentences with their trailing punctuation and space kept, so joining them restores
    /// the text.
    private static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var previousWasTerminator = false
        for character in text {
            if previousWasTerminator && character == " " {
                current.append(character)
                result.append(current)
                current = ""
                previousWasTerminator = false
                continue
            }
            current.append(character)
            previousWasTerminator = ".!?…".contains(character)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
