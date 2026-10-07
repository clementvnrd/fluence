import Foundation
import Testing

@testable import FluenceNotesCore

struct ChunkerTests {
    /// One token per word: makes budgets easy to reason about in tests.
    static func wordCount(_ text: String) -> Int {
        text.split(separator: " ").count
    }

    static func line(_ start: TimeInterval, _ speaker: String, words: Int) -> TranscriptLine {
        TranscriptLine(start: start, speaker: speaker, text: Array(repeating: "word", count: words).joined(separator: " "))
    }

    @Test func renderedLineFormat() {
        #expect(TranscriptLine(start: 75.9, speaker: "Marie", text: "Bonjour").rendered == "[01:15] Marie: Bonjour")
        #expect(Clock.format(3_725) == "1:02:05")
        #expect(Clock.format(-3) == "00:00")
    }

    @Test func emptyTranscriptHasNoChunks() {
        #expect(TranscriptChunker.chunk([], budget: 100).isEmpty)
        #expect(TranscriptChunker.chunk([TranscriptLine(start: 0, speaker: "A", text: "  ")], budget: 100).isEmpty)
    }

    @Test func shortTranscriptIsOneChunk() {
        let lines = [Self.line(0, "You", words: 5), Self.line(3, "Marie", words: 5)]
        let chunks = TranscriptChunker.chunk(lines, budget: 1_000, measure: Self.wordCount)
        #expect(chunks.count == 1)
        #expect(chunks[0].lines == lines)
        #expect(chunks[0].text == lines.map(\.rendered).joined(separator: "\n"))
    }

    @Test func cutsOnlyBetweenSpeakerTurns() {
        // Turns: You (2 lines), Marie (2 lines), You (1), Marie (2). Each line ~13 "tokens".
        let lines = [
            Self.line(0, "You", words: 10), Self.line(5, "You", words: 10),
            Self.line(10, "Marie", words: 10), Self.line(15, "Marie", words: 10),
            Self.line(20, "You", words: 10),
            Self.line(25, "Marie", words: 10), Self.line(30, "Marie", words: 10),
        ]
        let chunks = TranscriptChunker.chunk(lines, budget: 60, measure: Self.wordCount)
        #expect(chunks.count > 1)
        #expect(chunks.flatMap(\.lines) == lines, "every line kept, in order")
        for (left, right) in zip(chunks, chunks.dropFirst()) {
            #expect(left.lines.last?.speaker != right.lines.first?.speaker, "a cut never falls inside a turn")
        }
        for chunk in chunks {
            #expect(TranscriptChunker.cost(chunk.lines, Self.wordCount) <= 60)
        }
    }

    @Test func overlongTurnSplitsBetweenLines() {
        let lines = (0..<6).map { Self.line(Double($0) * 10, "Marie", words: 20) }
        let chunks = TranscriptChunker.chunk(lines, budget: 50, measure: Self.wordCount)
        #expect(chunks.flatMap(\.lines) == lines)
        #expect(chunks.allSatisfy { TranscriptChunker.cost($0.lines, Self.wordCount) <= 50 })
    }

    @Test func overlongLineSplitsAtSentencesThenWords() {
        let text = "First sentence is here. Second one follows now. "
            + Array(repeating: "endless", count: 40).joined(separator: " ")
        let line = TranscriptLine(start: 42, speaker: "Speaker 2", text: text)
        let chunks = TranscriptChunker.chunk([line], budget: 15, measure: Self.wordCount)
        let pieces = chunks.flatMap(\.lines)
        #expect(pieces.count > 2)
        #expect(pieces.allSatisfy { $0.speaker == "Speaker 2" && $0.start == 42 })
        #expect(pieces.first?.text == "First sentence is here. Second one follows now.")
        #expect(pieces.map(\.text).joined(separator: " ").split(separator: " ") == text.split(separator: " "))
        #expect(chunks.allSatisfy { TranscriptChunker.cost($0.lines, Self.wordCount) <= 15 })
    }

    @Test func chunksAreBalanced() {
        // 11 turns of 10 tokens with a budget of 50: greedy gives 4+4+3 turns... balancing
        // must not leave a scrap.
        let lines = (0..<11).map { Self.line(Double($0), $0 % 2 == 0 ? "A" : "B", words: 8) }
        let chunks = TranscriptChunker.chunk(lines, budget: 50, measure: Self.wordCount)
        let sizes = chunks.map(\.lines.count)
        #expect(sizes.reduce(0, +) == 11)
        #expect((sizes.max() ?? 0) - (sizes.min() ?? 0) <= 1)
    }

    @Test func realisticMeetingStaysUnderBudgetWithEstimate() {
        var lines: [TranscriptLine] = []
        for index in 0..<400 {
            lines.append(TranscriptLine(
                start: Double(index) * 9,
                speaker: ["You", "Marie Dupont", "Speaker 2"][index % 3],
                text: "On regarde le planning de la livraison et je pense qu'il faut décaler la démo à jeudi prochain."
            ))
        }
        let budget = NotesBudget(contextSize: 4_096).chunkTokens(hasUserNotes: true)
        let chunks = TranscriptChunker.chunk(lines, budget: budget)
        #expect(chunks.count > 1)
        #expect(chunks.flatMap(\.lines) == lines)
        #expect(chunks.allSatisfy { TokenEstimate.tokens(in: $0.text) <= budget })
    }

    @Test func budgetLeavesRoomForAnswer() {
        let budget = NotesBudget(contextSize: 4_096)
        #expect(budget.chunkTokens(hasUserNotes: false) == 2_500)
        #expect(budget.chunkTokens(hasUserNotes: true) == 2_296)
        #expect(budget.fits(promptTokens: 3_296))
        #expect(!budget.fits(promptTokens: 3_297))
        #expect(TokenEstimate.tokens(in: "") == 0)
        #expect(TokenEstimate.tokens(in: "abcd") == 2)
    }
}
