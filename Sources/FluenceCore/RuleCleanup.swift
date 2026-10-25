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
        // A full stop ends a sentence only when a space or a line break follows it: the dot
        // in "Node.js", "v2.1" or "example.com" is inside a word (FLU-20: "Node.Js").
        var afterTerminator = false
        let closers: Set<Character> = ["»", ")", "\"", "”", "’", "'"]
        for character in text {
            if afterTerminator {
                if character.isWhitespace {
                    capitalizeNext = true
                    afterTerminator = false
                } else if !closers.contains(character) {
                    afterTerminator = false
                }
            }
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
                if character == "\n" {
                    capitalizeNext = true
                } else if ".!?".contains(character) {
                    afterTerminator = true
                }
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
        // Layout commands: nobody says these words in a sentence about something else.
        let layout: [(String, String)] = [
            ("(?:nouveau|nouvel) paragraphe", "\n\n"),
            ("(?:retour [àa] la ligne|nouvelle ligne)", "\n"),
            // Not "à la ligne 3" or "à la ligne suivante": that is someone talking about a line.
            ("[àa] la ligne(?!\\s*(?:\\d|de\(end)|d\(apostrophe)|du\(end)|des\(end)|suivante|précédente))", "\n"),
            ("\(open) la parenth[èe]se", " ("),
            ("\(close) la parenth[èe]se", ") "),
            ("\(open) les guillemets", " « "),
            ("\(close) les guillemets", " » "),
        ]
        for (phrase, mark) in layout {
            let template = NSRegularExpression.escapedTemplate(for: mark)
            result = RuleCleanup.replace(result, "(?i)\(start)\(phrase)\(end)", with: template)
        }

        // Punctuation words are nouns as often as commands (FLU-30): « un point
        // d'interrogation sur le budget », « j'ai deux points à voir », « le point final du
        // projet ». A mark that closes a clause is a command only at a clause end — the end of
        // the text, a line break, or a mark the engine wrote itself — and none of them is one
        // after a determiner or an adjective, or before what completes a noun (« sur », « de »).
        let closers: [(String, String)] = [
            ("point d\(apostrophe)interrogation", "?"),
            ("point d\(apostrophe)exclamation", "!"),
            ("points? de suspension", "…"),
            ("point final", "."),
        ]
        for (phrase, mark) in closers {
            result = rewrite(result, phrase: phrase) { context in
                guard context.before != nil, !context.isNoun, context.atClauseEnd else { return nil }
                return .closingMark(mark)
            }
        }
        // A semicolon and a colon sit inside a sentence, so they may be followed by words.
        result = rewrite(result, phrase: "point[\\s-]virgule") { context in
            context.before == nil || context.isNoun ? nil : .closingMark(";")
        }
        // "deux points" is also a count (« j'ai deux points à voir ») and a score.
        result = rewrite(result, phrase: "deux points") { context in
            // Nothing before it to introduce: « Deux points à voir » opens a sentence.
            if context.before == nil { return nil }
            if let previous = context.previous, quantityWords.contains(previous) { return nil }
            if context.isNoun { return nil }
            return .mark(":")
        }
        // "virgule" between two digits is a decimal comma ("3 virgule 5" → "3,5"), and after a
        // determiner it is the noun (« la virgule », « un point-virgule » kept as words).
        result = rewrite(result, phrase: "virgule") { context in
            if context.before == "-" || context.previous == "point" { return nil }
            if let previous = context.previous, determiners.contains(previous) { return nil }
            if let previous = context.previous, let next = context.next,
               previous.allSatisfy(\.isNumber), next.first?.isNumber == true {
                return .decimalComma
            }
            return .mark(",")
        }
        // "point" only where nothing but a full stop fits: at the very end, before a line
        // break, or before the full stop the engine already wrote (« …le devis point. », F5),
        // which it replaces. Never after a determiner, a preposition or an adjective (« à ce
        // point », « excellent point »).
        result = rewrite(result, phrase: "point") { context in
            // A number before it stays a command: « rendez-vous à 15 h point ».
            if let previous = context.previous, nounBefore.contains(previous) { return nil }
            let afterStop = context.previous == nil && context.before.map { ".!?".contains($0) } == true
            if context.next == nil || context.next == "\n" {
                // « …le devis. Point » : the engine's stop already is the one that was said.
                return afterStop ? .drop : .closingMark(".")
            }
            guard context.next == "." else { return nil }
            return afterStop ? .drop : .closingMark(".")
        }
        return result
    }

    /// What surrounds a spoken punctuation word.
    struct Context {
        /// The word before, lowercased, elisions read as the word after the apostrophe
        /// (« j'ai » → « ai »); nil when a mark or the start of the text comes first.
        let previous: String?
        /// The next word, "\n", or the mark that follows; nil at the end of the text.
        let next: String?
        /// The character right before the phrase, spaces skipped.
        let before: Character?

        /// The phrase reads as a noun: after a determiner, an adjective or a number, or
        /// before what completes a noun.
        var isNoun: Bool {
            if let previous, nounBefore.contains(previous) || isNumberOrOrdinal(previous) { return true }
            if let next, nounAfter.contains(next.lowercased()) { return true }
            return false
        }

        /// The end of the text, a line break, or a mark the engine wrote.
        var atClauseEnd: Bool {
            guard let next else { return true }
            return next == "\n" || pauses.contains(next)
        }
    }

    enum Action {
        /// The mark; an engine's own mark right after the phrase gives way to it.
        case mark(String)
        /// The same, and a comma the engine wrote before it goes too (« devis, point »).
        case closingMark(String)
        /// A comma glued to the digits around it.
        case decimalComma
        /// The phrase and the engine's stop after it go: the stop before already says it.
        case drop
    }

    /// Replaces each whole-word `phrase` with what `decide` returns for its context, or
    /// leaves it when that is nil.
    private static func rewrite(
        _ text: String,
        phrase: String,
        decide: (Context) -> Action?
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
            let context = Context(
                previous: previousWord(in: result, before: range.lowerBound),
                next: nextWord(in: result, after: range.upperBound),
                before: result[..<range.lowerBound].last(where: { $0 != " " && $0 != "\t" })
            )
            guard let action = decide(context) else { continue }
            var lower = range.lowerBound
            var upper = range.upperBound
            let replacement: String
            switch action {
            case .mark(let mark):
                replacement = mark
                upper = engineMark(in: result, after: upper) ?? upper
            case .closingMark(let mark):
                replacement = mark
                upper = engineMark(in: result, after: upper) ?? upper
                var cursor = lower
                while cursor > result.startIndex, result[result.index(before: cursor)] == " " {
                    cursor = result.index(before: cursor)
                }
                if cursor > result.startIndex, result[result.index(before: cursor)] == "," {
                    lower = result.index(before: cursor)
                }
            case .decimalComma:
                replacement = ","
                while lower > result.startIndex, result[result.index(before: lower)] == " " {
                    lower = result.index(before: lower)
                }
                while upper < result.endIndex, result[upper] == " " { upper = result.index(after: upper) }
            case .drop:
                replacement = ""
                while lower > result.startIndex, result[result.index(before: lower)] == " " {
                    lower = result.index(before: lower)
                }
                upper = engineMark(in: result, after: upper) ?? upper
            }
            result.replaceSubrange(lower..<upper, with: replacement)
        }
        return result
    }

    /// The end of a mark the engine wrote right after `index` (spaces skipped), if any.
    private static func engineMark(in text: String, after index: String.Index) -> String.Index? {
        var cursor = index
        while cursor < text.endIndex, text[cursor] == " " { cursor = text.index(after: cursor) }
        guard cursor < text.endIndex, pauses.contains(String(text[cursor])) else { return nil }
        return text.index(after: cursor)
    }

    private static func previousWord(in text: String, before index: String.Index) -> String? {
        let head = text[..<index].trimmingCharacters(in: .whitespaces)
        guard let last = head.last, last.isLetter || last.isNumber || last == "'" || last == "’" else { return nil }
        let word = head.reversed().prefix { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "’" }
        let forward = String(word.reversed()).lowercased()
        // « j'ai », « qu'un »: the word that counts is the one after the elision.
        if let apostrophe = forward.lastIndex(where: { $0 == "'" || $0 == "’" }) {
            let after = forward[forward.index(after: apostrophe)...]
            let elided = forward[..<apostrophe]
            return after.isEmpty ? String(elided) : String(after)
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

    static func isNumberOrOrdinal(_ word: String) -> Bool {
        word.allSatisfy(\.isNumber) || word.hasSuffix("ième") || word.hasSuffix("ièmes")
            || SpeechRepairs.RevisionKind.numberWords.contains(word)
    }

    /// Marks an engine writes at a pause.
    static let pauses: Set<String> = [".", ",", ";", ":", "!", "?", "…"]

    private static let determiners: Set<String> = [
        "le", "la", "l", "les", "un", "une", "ce", "cet", "cette", "ces", "du", "de", "d", "des",
        "au", "aux", "mon", "ma", "mes", "ton", "ta", "tes", "son", "sa", "ses", "notre", "votre",
        "nos", "vos", "leur", "leurs", "quel", "quelle", "quels", "quelles", "chaque", "tel", "telle",
    ]
    private static let prepositions: Set<String> = ["à", "a", "en", "sur", "par", "vers", "bon", "mauvais"]
    /// Adjectives and quantifiers that come before a noun: « excellent point », « gros point
    /// d'interrogation », « plusieurs points de suspension ».
    private static let adjectives: Set<String> = [
        "excellent", "bon", "bons", "mauvais", "gros", "petit", "petits", "grand", "grands", "vrai",
        "vrais", "dernier", "derniers", "premier", "premiers", "seul", "seuls", "autre", "autres",
        "même", "mêmes", "nouveau", "nouveaux", "nouvel", "sacré", "joli", "beau", "beaux", "bel",
        "sale", "énorme", "énormes", "léger", "simple", "simples", "quelques", "plusieurs",
        "certains", "divers", "tout", "tous", "moindre", "unique", "principal", "véritable",
    ]
    static let nounBefore: Set<String> = determiners.union(prepositions).union(adjectives)
    /// Words that complete a noun right after it: « point d'interrogation sur le budget »,
    /// « deux points à voir », « deux points importants ».
    static let nounAfter: Set<String> = [
        "sur", "de", "d", "du", "des", "à", "au", "aux", "qui", "que", "qu", "dont", "dans", "en",
        "pour", "concernant", "quant", "entre", "avec", "chez",
        "important", "importants", "importante", "essentiel", "essentiels", "principal", "principaux",
        "commun", "communs", "fort", "forts", "faible", "faibles", "clé", "clés", "crucial", "cruciaux",
        "positif", "positifs", "négatif", "négatifs", "majeur", "majeurs", "bloquant", "bloquants",
        "ouvert", "ouverts", "précis", "noir", "noirs",
    ]
    private static let quantityWords: Set<String> = determiners.union([
        "à", "avec", "sur", "en", "par", "marqué", "gagné", "perdu", "obtenu", "pris", "rendu",
        "plus", "moins", "que", "seulement", "environ",
        // Having or lacking two of something: « j'ai deux points à voir ».
        "ai", "as", "a", "avons", "avez", "ont", "avait", "avais", "aura", "auras", "reste",
        "restent", "manque", "manquent", "encore", "derniers", "premiers", "autres",
    ])
}
