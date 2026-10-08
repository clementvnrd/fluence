import Foundation

/// Whether a transcript is something a person said, or a speech engine stuck in a loop
/// (FLU-20: one dictionary term repeated thirty times). A looped transcript is never pasted:
/// the engine is asked again without its prompt, and if it still loops, the dictation fails
/// with a message rather than typing nonsense into the user's document.
public enum TranscriptHealth {
    /// Below this many words there is too little to judge: "non non non" is a real answer.
    static let minimumWords = 6

    public static func isDegenerate(_ text: String) -> Bool {
        let words = normalizedWords(text)
        guard words.count >= minimumWords else { return false }
        return longestRepeat(in: words) || dominantWord(in: words)
    }

    /// The same 1–4-word group back to back: 5 times for one word ("Node.js, Node.js, …"),
    /// 4 times for a longer group ("on y va, on y va, …"). People double a word for emphasis
    /// ("très très"), they don't say it five times in a row.
    static func longestRepeat(in words: [String]) -> Bool {
        for size in 1...4 {
            let needed = size == 1 ? 5 : 4
            guard words.count >= size * needed else { continue }
            var start = 0
            while start + size * needed <= words.count {
                let group = words[start..<(start + size)]
                var repeats = 1
                var next = start + size
                while next + size <= words.count, words[next..<(next + size)] == group {
                    repeats += 1
                    next += size
                }
                if repeats >= needed { return true }
                start += 1
            }
        }
        return false
    }

    /// One content word making up more than 40 % of a longer transcript.
    static func dominantWord(in words: [String]) -> Bool {
        guard words.count >= 12 else { return false }
        var counts: [String: Int] = [:]
        for word in words where word.count >= 3 { counts[word, default: 0] += 1 }
        guard let top = counts.values.max() else { return false }
        return Double(top) / Double(words.count) > 0.4
    }

    /// Lowercased words, punctuation around them removed; the dot inside "node.js" stays.
    static func normalizedWords(_ text: String) -> [String] {
        let edges = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespaces)
        return text
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: edges) }
            .filter { !$0.isEmpty }
    }
}

/// The context handed to Whisper before it transcribes (FLU-20).
///
/// Whisper continues its prompt. A bare list of thirty terms ("…, Next.js, Node.js, Vue.js")
/// teaches it to continue the list instead of transcribing, and the long prompt also eats the
/// window's token budget. So the prompt is one short sentence: the end of the previous
/// dictation when it is recent and healthy, then a handful of the user's own terms.
public enum WhisperPrompt {
    public static let maximumTerms = 8
    public static let maximumCharacters = 220

    /// - Parameters:
    ///   - previous: the last dictation's text, if it was recent.
    ///   - terms: the dictionary's spellings, most relevant first.
    ///   - french: whether the dictation language is French, for the sentence's wording.
    /// - Returns: nil when there is nothing worth saying.
    public static func build(previous: String?, terms: [String], french: Bool) -> String? {
        var parts: [String] = []

        if let previous, !TranscriptHealth.isDegenerate(previous) {
            let sentences = previous
                .components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if let last = sentences.last {
                let words = last.split(whereSeparator: { $0.isWhitespace }).suffix(15)
                parts.append(words.joined(separator: " ") + ".")
            }
        }

        var seen = Set<String>()
        let chosen = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
            .prefix(maximumTerms)
        if !chosen.isEmpty {
            parts.append((french ? "Vocabulaire : " : "Vocabulary: ") + list(Array(chosen), french: french) + ".")
        }

        guard !parts.isEmpty else { return nil }
        var prompt = parts.joined(separator: " ")
        if prompt.count > maximumCharacters {
            prompt = String(prompt.suffix(maximumCharacters))
        }
        return prompt
    }

    /// "a, b et c" / "a, b and c": a sentence, not a list to continue.
    static func list(_ items: [String], french: Bool) -> String {
        guard items.count > 1 else { return items.first ?? "" }
        return items.dropLast().joined(separator: ", ") + (french ? " et " : " and ") + items.last!
    }
}
