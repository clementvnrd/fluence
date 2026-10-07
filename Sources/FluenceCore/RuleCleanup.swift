import Foundation

/// The deterministic cleanup pass (level Light), and the fallback for every model pass.
///
/// It can only delete fillers, turn spoken punctuation into marks, and fix spacing and
/// capitals — never introduce a word — which is what makes it safe as the fallback when the
/// model is unavailable, slow, or rejected by `CleanupGuard`.
///
/// Language-aware because fillers and spoken punctuation are: "euh" is a filler in French
/// and "point" is a full stop, while in English neither means anything. A language without
/// its own rules (German, Polish…) gets only the neutral steps rather than English rules
/// that would misfire on it.
public enum RuleCleanup {
    public static func apply(_ raw: String, language: DictationLanguage) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        switch language {
        case .english, .auto:
            text = EnglishRules.stripFillers(text)
            text = EnglishRules.spokenPunctuation(text)
        case .french:
            text = FrenchRules.stripFillers(text)
            text = FrenchRules.spokenPunctuation(text)
        default:
            text = replace(text, "(?i)\(fenceStart)(?:h+m+|m+h+m+)\(fenceEnd),?", with: "")
        }

        text = collapseWhitespace(text)
        text = capitalizeSentences(text)
        text = ensureTerminalPunctuation(text)
        if language == .french { text = FrenchTypography.apply(to: text) }
        return text
    }

    // MARK: - Neutral steps

    static func collapseWhitespace(_ text: String) -> String {
        var result = text
        let steps: [(String, String)] = [
            ("[ \\t]+", " "),
            // Spoken line breaks leave the spaces that surrounded the command.
            (" *\\n *", "\n"),
            (" +([,.!?;:…)])", "$1"),
            ("\\( +", "("),
            // A filler removed between two commas leaves one.
            (",(?:\\s*,)+", ","),
            ("^[\\s,]+", ""),
            ("\\n{3,}", "\n\n"),
        ]
        for (pattern, template) in steps {
            result = replace(result, pattern, with: template)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func capitalizeSentences(_ text: String) -> String {
        var result = ""
        var capitalizeNext = true
        for character in text {
            if capitalizeNext, character.isLetter {
                result.append(contentsOf: character.uppercased())
                capitalizeNext = false
            } else if character == SnippetMatcher.placeholderOpen {
                // A snippet placeholder stands for a word: its expansion keeps its own case,
                // and the word after it is mid-sentence.
                result.append(character)
                capitalizeNext = false
            } else {
                result.append(character)
                if ".!?\n".contains(character) { capitalizeNext = true }
            }
        }
        return result
    }

    static func ensureTerminalPunctuation(_ text: String) -> String {
        // Look through closing quotes and brackets: «oui» and (draft) still end a sentence
        // that needs its full stop.
        let closers: Set<Character> = ["»", ")", "\"", "”", "’", " ", "\u{00A0}"]
        guard let last = text.last(where: { !closers.contains($0) }), last.isLetter || last.isNumber else {
            return text
        }
        return text + "."
    }

    // MARK: - Regex plumbing

    /// No letter, digit or apostrophe immediately before: a whole word starts here.
    static let fenceStart = "(?<![\\p{L}\\p{N}'’])"
    /// No letter or digit immediately after: the word ends here.
    static let fenceEnd = "(?![\\p{L}\\p{N}])"

    static func replace(_ text: String, _ pattern: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}

// MARK: - English

enum EnglishRules {
    /// Unchanged from the original rule pass: these are never words in English.
    private static let fillers = ["um", "uh", "erm", "uhm", "hmm", "mhm"]

    private static let spoken: [(String, String)] = [
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("open paren", " ("),
        ("close paren", ") "),
    ]

    static func stripFillers(_ text: String) -> String {
        var result = text
        for filler in fillers {
            // The filler as a whole word, plus a trailing comma if the engine added one.
            result = RuleCleanup.replace(result, "(?i)(?<![\\w'])\(filler)\\b,?", with: "")
        }
        return result
    }

    static func spokenPunctuation(_ text: String) -> String {
        var result = text
        for (phrase, replacement) in spoken {
            result = RuleCleanup.replace(result, "(?i)\\b\(phrase)\\b", with: replacement)
        }
        return result
    }
}

// MARK: - French

/// French fillers and dictation commands, deliberately conservative.
///
/// Every rule here deletes or rewrites words, and a French sentence is full of words that
/// are fillers only sometimes: "ben" is also a first name, "genre" a noun ("un genre de"),
/// "point" a noun ("le point important"), "deux points" a score. Each ambiguous word is only
/// touched in the shapes where it can't be anything else; "voilà", "bon", "quoi" and
/// "hein" are left alone entirely. A filler left in costs the user a backspace; a word
/// wrongly removed changes what they said.
enum FrenchRules {
    private static let start = RuleCleanup.fenceStart
    private static let end = RuleCleanup.fenceEnd
    private static let apostrophe = "['’]"

    /// Words that, right after "ben" or "bah", make it an interjection ("ben oui", "bah non").
    private static let discourse = "(?:oui|non|alors|euh|voilà|voila|écoute|écoutez|disons|si|ouais|bon)"

    static func stripFillers(_ text: String) -> String {
        var result = text
        // Pure hesitation sounds — never words.
        result = RuleCleanup.replace(result, "(?i)\(start)(?:e+u+h+m?|h+e+u+h*|h+u+m+|h+m+|m+h+m+)\(end),?", with: "")
        // "bah" is never a name: an interjection before a comma or a discourse word.
        result = RuleCleanup.replace(
            result, "(?i)\(start)bah(?:\\s*,|(?=\\s+\(discourse)\(end)))", with: "")
        // "ben" is also "Ben": lowercase before a comma, or any case before "oui", "non"…
        result = RuleCleanup.replace(result, "\(start)ben\\s*,", with: "")
        result = RuleCleanup.replace(result, "(?i)\(start)ben(?=\\s+\(discourse)\(end))", with: "")
        // "genre" only between commas or opening a sentence with a comma — never "un genre de".
        result = RuleCleanup.replace(result, "(?i),\\s*genre\\s*,", with: ",")
        result = RuleCleanup.replace(result, "(?i)(^|[.!?…]\\s*|\\n)genre\\s*,\\s*", with: "$1")
        // "du coup" between commas, or trailing at the end of a sentence. Opening a sentence
        // it is a connector ("so"), and stays.
        result = RuleCleanup.replace(result, "(?i),\\s*du coup\\s*,", with: ",")
        result = RuleCleanup.replace(result, "(?i),?\\s*\(start)du coup\(end)\\s*(?=[.!?…]|$)", with: "")
        return result
    }

    static func spokenPunctuation(_ text: String) -> String {
        var result = text
        let open = "(?:ouvrez|ouvre|ouvrir|ouvrons)"
        let close = "(?:fermez|ferme|fermer|fermons)"
        let fixed: [(String, String)] = [
            ("point d\(apostrophe)interrogation", "?"),
            ("point d\(apostrophe)exclamation", "!"),
            ("points? de suspension", "…"),
            ("point[\\s-]virgule", ";"),
            ("(?:nouveau|nouvel) paragraphe", "\n\n"),
            ("(?:retour [àa] la ligne|nouvelle ligne)", "\n"),
            // Not "à la ligne 3" or "à la ligne suivante": that is someone talking about a line.
            ("[àa] la ligne(?!\\s*(?:\\d|de\(end)|d\(apostrophe)|du\(end)|des\(end)|suivante|précédente))", "\n"),
            ("\(open) la parenth[èe]se", " ("),
            ("\(close) la parenth[èe]se", ") "),
            ("\(open) les guillemets", " « "),
            ("\(close) les guillemets", " » "),
            ("point final", "."),
        ]
        for (phrase, mark) in fixed {
            let template = NSRegularExpression.escapedTemplate(for: mark)
            result = RuleCleanup.replace(result, "(?i)\(start)\(phrase)\(end)", with: template)
        }

        // "deux points" is also a score: not after words that count things.
        result = rewrite(result, phrase: "deux points") { previous, _ in
            guard let previous else { return ":" }
            return quantityWords.contains(previous) ? nil : ":"
        }
        // "virgule" between two digits is a decimal comma ("3 virgule 5" → "3,5"), and after a
        // determiner it is the noun ("la virgule").
        result = rewrite(result, phrase: "virgule") { previous, next in
            if let previous, determiners.contains(previous) { return nil }
            if let previous, let next, previous.allSatisfy(\.isNumber), next.first?.isNumber == true {
                return "\u{0},"
            }
            return ","
        }
        // "point" only where nothing but a full stop fits: at the very end, or right before a
        // line break — and never after a determiner ("à ce point", "le point").
        result = rewrite(result, phrase: "point") { previous, next in
            if let previous, determiners.contains(previous) || prepositions.contains(previous) { return nil }
            guard next == nil || next == "\n" else { return nil }
            return "."
        }
        return result
    }

    /// Replaces each whole-word `phrase` with what `decide` returns for its neighbours (the
    /// previous word lowercased, the next word or "\n"), or leaves it when that is nil.
    /// A result starting with NUL also swallows the spaces on both sides.
    private static func rewrite(
        _ text: String,
        phrase: String,
        decide: (_ previous: String?, _ next: String?) -> String?
    ) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: "\(start)\(phrase.replacingOccurrences(of: " ", with: "\\s+"))\(end)",
            options: [.caseInsensitive]
        ) else { return text }

        var result = text
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // Back to front, so earlier ranges stay valid as later ones are rewritten.
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let previous = previousWord(in: result, before: range.lowerBound)
            let next = nextWord(in: result, after: range.upperBound)
            guard var mark = decide(previous, next) else { continue }
            var lower = range.lowerBound
            var upper = range.upperBound
            if mark.first == "\u{0}" {
                mark.removeFirst()
                while lower > result.startIndex, result[result.index(before: lower)] == " " {
                    lower = result.index(before: lower)
                }
                while upper < result.endIndex, result[upper] == " " { upper = result.index(after: upper) }
            }
            result.replaceSubrange(lower..<upper, with: mark)
        }
        return result
    }

    private static func previousWord(in text: String, before index: String.Index) -> String? {
        let head = text[..<index].trimmingCharacters(in: .whitespaces)
        guard let last = head.last, last.isLetter || last.isNumber || last == "'" || last == "’" else { return nil }
        let word = head.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
        let forward = String(word.reversed()).lowercased()
        // "l'" / "d'" elisions read as their determiner.
        if let apostrophe = forward.lastIndex(where: { $0 == "'" || $0 == "’" }) {
            let elided = forward[..<apostrophe]
            return elided.isEmpty ? forward : String(elided)
        }
        return forward
    }

    private static func nextWord(in text: String, after index: String.Index) -> String? {
        let tail = text[index...].drop { $0 == " " || $0 == "\t" }
        guard let first = tail.first else { return nil }
        if first == "\n" { return "\n" }
        let word = tail.prefix { $0.isLetter || $0.isNumber }
        return word.isEmpty ? String(first) : String(word)
    }

    private static let determiners: Set<String> = [
        "le", "la", "l", "les", "un", "une", "ce", "cet", "cette", "ces", "du", "de", "d", "des",
        "au", "aux", "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "notre", "votre",
        "nos", "vos", "leur", "leurs", "quel", "quelle", "quels", "quelles", "chaque", "tel", "telle",
    ]
    private static let prepositions: Set<String> = ["à", "a", "en", "sur", "par", "vers", "bon", "mauvais"]
    private static let quantityWords: Set<String> = determiners.union([
        "à", "avec", "sur", "en", "par", "marqué", "gagné", "perdu", "obtenu", "pris", "rendu",
        "plus", "moins", "que", "seulement", "environ",
    ])
}
