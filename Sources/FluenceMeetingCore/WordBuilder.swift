import Foundation

/// One sub-word token from the recogniser, timed relative to the utterance.
public struct TimedToken: Sendable, Hashable {
    public var text: String
    public var start: TimeInterval
    public var end: TimeInterval
    public var confidence: Float

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

/// Groups SentencePiece tokens into words on the meeting clock.
///
/// A token starting with the word-boundary marker `▁` (U+2581) or a space begins a new
/// word; any other token continues the current one. A word spans its first token's start
/// to its last token's end, plus `offset`; its confidence is the lowest of its tokens'.
/// `<blank>`, `<pad>` and empty tokens are skipped.
public enum WordBuilder {
    public static let boundary: Character = "\u{2581}"

    public static func words(from tokens: [TimedToken], offset: TimeInterval) -> [Word] {
        var words: [Word] = []
        var current: Word?

        func flush() {
            guard var word = current else { return }
            word.text = word.text.trimmingCharacters(in: .whitespaces)
            if !word.text.isEmpty { words.append(word) }
            current = nil
        }

        for token in tokens {
            let raw = token.text
            guard !raw.isEmpty, raw != "<blank>", raw != "<pad>" else { continue }
            let startsWord = raw.first == boundary || raw.first == " "
            let piece = startsWord ? String(raw.drop { $0 == boundary || $0 == " " }) : raw

            if startsWord || current == nil {
                flush()
                current = Word(
                    text: piece,
                    start: token.start + offset,
                    end: token.end + offset,
                    confidence: token.confidence
                )
            } else if var word = current {
                word.text += piece
                word.end = token.end + offset
                word.confidence = min(word.confidence ?? token.confidence, token.confidence)
                current = word
            }
        }
        flush()
        return words
    }
}
