import Foundation

/// The cleanup pass between raw transcription and injection.
///
/// This is where Wispr Flow actually earns its keep — raw STT output is full of filler
/// words, missing punctuation, and spoken corrections. Swapping in an LLM-backed
/// formatter (Apple Foundation Models on-device, or Claude for the high-quality tier)
/// is the point of keeping this behind a protocol.
protocol TextFormatter: Sendable {
    func format(_ raw: String) async -> String
    func format(_ raw: String, context: AppContextDetector.AppContext?) async -> String
}

extension TextFormatter {
    func format(_ raw: String) async -> String {
        await format(raw, context: nil)
    }
}

/// Deterministic, zero-latency cleanup. Good enough to be useful on its own and always
/// the fallback when a model-backed formatter is unavailable or times out.
struct RuleBasedFormatter: TextFormatter {
    /// Standalone filler words, stripped only when surrounded by word boundaries.
    private static let fillers = [
        "um", "uh", "erm", "uhm", "hmm", "mhm",
        "euh", "euhm", "euhh", "euhhh", "heu", "heuu", "bah", "ben", "genre", "hum"
    ]

    /// Spoken punctuation people actually use mid-dictation in English and French.
    private static let spokenPunctuation: [(String, String)] = [
        ("point d'interrogation", "?"),
        ("point d'exclamation", "!"),
        ("point virgule", ";"),
        ("deux points", ":"),
        ("nouveau paragraphe", "\n\n"),
        ("nouvelle ligne", "\n"),
        ("à la ligne", "\n"),
        ("ouvrez la parenthèse", " ("),
        ("ouvre la parenthèse", " ("),
        ("fermez la parenthèse", ") "),
        ("ferme la parenthèse", ") "),
        ("ouvrez les guillemets", " « "),
        ("fermez les guillemets", " » "),
        ("point final", "."),
        ("virgule", ","),
        ("new paragraph", "\n\n"),
        ("new line", "\n"),
        ("question mark", "?"),
        ("exclamation mark", "!"),
        ("open paren", " ("),
        ("close paren", ") "),
    ]

    func format(_ raw: String) async -> String {
        await format(raw, context: nil)
    }

    func format(_ raw: String, context: AppContextDetector.AppContext?) async -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        text = applyBacktrackingCorrections(to: text)
        text = stripFillers(from: text)
        text = deduplicateConsecutiveWords(in: text)
        text = removeStutterPrefixes(in: text)
        text = applyGrammaticalCorrections(to: text)
        text = applySpokenPunctuation(to: text)
        if let context, context.category == .developer {
            text = applyDeveloperCodeFormatting(to: text)
        }
        text = applySmartLists(to: text)
        text = smoothConversationalTransitions(in: text)
        text = collapseWhitespace(in: text)
        text = capitalizeSentences(in: text)
        text = applyContextualPunctuation(to: text, context: context)

        return text
    }

    private func stripFillers(from text: String) -> String {
        var result = text
        for filler in Self.fillers {
            // Match the filler as a whole word, plus a trailing comma if the ASR added one.
            let pattern = "(?i)(?<![\\p{L}\\w'])\(filler)\\b,?"
            result = result.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        return result
    }

    private func applySpokenPunctuation(to text: String) -> String {
        var result = text
        for (phrase, replacement) in Self.spokenPunctuation {
            result = result.replacingOccurrences(
                of: "(?i)\\b\(phrase)\\b",
                with: replacement,
                options: .regularExpression
            )
        }
        return result
    }

    private func collapseWhitespace(in text: String) -> String {
        text
            .replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: " +([,.!?;:])", with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func capitalizeSentences(in text: String) -> String {
        var result = ""
        var capitalizeNext = true

        for character in text {
            if capitalizeNext, character.isLetter {
                result.append(Character(character.uppercased()))
                capitalizeNext = false
            } else {
                result.append(character)
                if ".!?\n".contains(character) { capitalizeNext = true }
            }
        }
        return result
    }

    // MARK: - Backtracking & Self-Corrections

    /// Discards false starts, verbal cancellations, or replaces revised words mid-sentence.
    private func applyBacktrackingCorrections(to text: String) -> String {
        var result = text

        // 1. Verbal cancellations
        if let scratchRange = result.range(
            of: #"(?i)\b(?:scratch that|delete that|efface tout|efface ça|annule tout|annule ça|supprime ça)\b"#,
            options: [.regularExpression, .backwards]
        ) {
            result = String(result[scratchRange.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 2. Mid-sentence word revisions with Unicode letter support (\p{L})
        let replacePattern = #"(?i)\b([\p{L}0-9_]+)\s*(?:,\s*actually|,\s*en fait|\s+no wait|\s+make that|\s+i meant|\s+or actually|\s+non attends|\s+ou plutôt|\s+je voulais dire)\s+([\p{L}0-9_]+)\b"#
        result = result.replacingOccurrences(of: replacePattern, with: "$2", options: .regularExpression)

        return result
    }

    // MARK: - Smart Lists

    /// Formats spoken enumerations into markdown bullet points or numbered lists.
    /// Supports spoken ordinals ("premièrement...", "deuxièmement...") and spoken bullet cues ("bullet point", "boulette de pot").
    private func applySmartLists(to text: String) -> String {
        var result = text

        // 1. Spoken bullet points & French phonetic misrecognitions ("boulettes de pot", "bullet point", "bullet points", "puce", "tiret")
        result = result.replacingOccurrences(
            of: #"(?i)(^|[,.;:!?\n]\s*)(?:bullet\s+points?|boulettes?\s+de\s+pot|tiret|puce)\s*,?\s*"#,
            with: "\n- ",
            options: .regularExpression
        )

        // 2. Spoken French & English ordinals ("premièrement...", "deuxièmement...", "firstly...", "secondly...")
        let ordinals: [(String, String)] = [
            ("premièrement|en premier", "1"),
            ("deuxièmement|en deuxième", "2"),
            ("troisièmement|en troisième", "3"),
            ("quatrièmement|en quatrième", "4"),
            ("cinquièmement|en cinquième", "5"),
            ("firstly|first of all", "1"),
            ("secondly|second of all", "2"),
            ("thirdly", "3")
        ]
        for (ord, num) in ordinals {
            result = result.replacingOccurrences(
                of: "(?i)(^|[,.;:!?\\n]\\s*)(?:donc\\s+)?(?:\(ord))\\s*,?\\s*",
                with: "\n\(num). ",
                options: .regularExpression
            )
        }

        let numberWords: [String: String] = [
            "one": "1", "two": "2", "three": "3", "four": "4", "five": "5",
            "six": "6", "seven": "7", "eight": "8", "nine": "9", "ten": "10",
            "un": "1", "deux": "2", "trois": "3", "quatre": "4", "cinq": "5",
            "sept": "7", "huit": "8", "neuf": "9", "dix": "10"
        ]

        // Handle digits: "number 1", "numéro 1"
        result = result.replacingOccurrences(
            of: #"(?i)(?:^|(?<=[.!?\n]\s*))(?:number|numéro)\s+(\d+)\s+"#,
            with: "\n$1. ",
            options: .regularExpression
        )

        // Handle word numbers: "number one", "numéro un", etc.
        for (word, digit) in numberWords {
            result = result.replacingOccurrences(
                of: "(?i)(?:^|(?<=[.!?\\n]\\s*))(?:number|numéro)\\s+\(word)\\s+",
                with: "\n\(digit). ",
                options: .regularExpression
            )
        }

        return result
    }

    // MARK: - Grammatical & Phonetic Speech Corrections

    private func applyGrammaticalCorrections(to text: String) -> String {
        var result = text
        // Fix French spoken phonetic confusion: "les énormes œils" -> "les énormes yeux"
        result = result.replacingOccurrences(
            of: #"(?i)\b(les|des|mes|tes|ses|nos|vos|leurs|énormes|beaux|grands|petits)\s+œils\b"#,
            with: "$1 yeux",
            options: .regularExpression
        )
        return result
    }

    // MARK: - Developer / Code Formatting

    private func applyDeveloperCodeFormatting(to text: String) -> String {
        var result = text

        // 1. Spoken CLI flags: "double tiret [mot]" or "tiret tiret [mot]" -> "--$1", "tiret [mot]" -> "-$1"
        result = result.replacingOccurrences(
            of: #"(?i)\b(?:double tiret|tiret tiret|dash dash)\s+([a-zA-Z0-9_\-]+)\b"#,
            with: "--$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\b(?:tiret simple|single dash)\s+([a-zA-Z0-9_\-]+)\b"#,
            with: "-$1",
            options: .regularExpression
        )

        // 2. Code braces and brackets
        let codeSymbols: [(String, String)] = [
            ("accolade ouvrante", "{"),
            ("accolade fermante", "}"),
            ("crochet ouvrant", "["),
            ("crochet fermant", "]"),
            ("anti slash", "\\"),
            ("point barre", "/"),
            ("égal égal", "=="),
            ("différent de", "!="),
            ("flèche droite", "->"),
            ("grosse flèche", "=>")
        ]
        for (spoken, symbol) in codeSymbols {
            result = result.replacingOccurrences(
                of: "(?i)\\b\(spoken)\\b",
                with: symbol,
                options: .regularExpression
            )
        }

        return result
    }

    // MARK: - Contextual Punctuation

    private func applyContextualPunctuation(to text: String, context: AppContextDetector.AppContext?) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, last.isLetter || last.isNumber else { return trimmed }

        if let context, context.shouldSuppressTrailingPeriod {
            // For developer tools / terminals, suppress trailing period for single-line commands or code
            // (e.g. `brew install ripgrep`, `python train.py`, `git commit`, `cat file.txt`)
            // Only add trailing period if the text contains multiple sentences or explicit ending punctuation
            if !trimmed.contains("\n") && !trimmed.contains(". ") {
                return trimmed
            }
        }

        return trimmed + "."
    }

    // MARK: - Deduplication & Stutter Removal

    /// Deduplicates words or contractions that are repeated due to speech hesitations (e.g. "c'est c'est" -> "c'est", "dans dans" -> "dans").
    private func deduplicateConsecutiveWords(in text: String) -> String {
        let emphaticAllowed: Set<String> = [
            "très", "trop", "fort", "loin", "long", "jamais", "non", "oui", "bye", "merci",
            "very", "too", "so", "really", "no", "yes"
        ]

        var current = text

        // 1. Multi-word phrases: e.g. "plein de plein de", "il y a il y a"
        let phrasePattern = #"(?i)(?<![\p{L}0-9_])([\p{L}]+['’]?[\p{L}]*(?:\s+[\p{L}]+['’]?[\p{L}]*){1,2})\s+\1(?![0-9\p{L}_])"#
        if let regex = try? NSRegularExpression(pattern: phrasePattern) {
            var changed = true
            var passes = 0
            while changed && passes < 5 {
                changed = false
                passes += 1
                let matches = regex.matches(in: current, range: NSRange(current.startIndex..., in: current))
                if let match = matches.first, let range = Range(match.range, in: current) {
                    let full = String(current[range])
                    let half = full.count / 2
                    let firstPart = String(full.prefix(upTo: full.index(full.startIndex, offsetBy: half))).trimmingCharacters(in: .whitespaces)
                    if !emphaticAllowed.contains(firstPart.lowercased()) {
                        current.replaceSubrange(range, with: firstPart)
                        changed = true
                    }
                }
            }
        }

        // 2. Contractions: e.g. "c'est c'est", "j'ai j'ai", "d'un d'un", "qu'il qu'il"
        let contractionPattern = #"(?i)(?<![\p{L}0-9_])([\p{L}]+['’][\p{L}]+)\s+\1(?![0-9\p{L}_])"#
        if let regex = try? NSRegularExpression(pattern: contractionPattern) {
            var changed = true
            var passes = 0
            while changed && passes < 5 {
                changed = false
                passes += 1
                let matches = regex.matches(in: current, range: NSRange(current.startIndex..., in: current))
                if let match = matches.first, let range = Range(match.range, in: current) {
                    let fullMatch = String(current[range])
                    let parts = fullMatch.components(separatedBy: .whitespaces)
                    if let first = parts.first, !emphaticAllowed.contains(first.lowercased()) {
                        current.replaceSubrange(range, with: first)
                        changed = true
                    }
                }
            }
        }

        // 2. Standard single words: e.g. "dans dans", "le le", "je je", "the the"
        let wordPattern = #"(?i)(?<![\p{L}0-9_'])([\p{L}]+)\s+\1(?![0-9\p{L}_'])"#
        if let regex = try? NSRegularExpression(pattern: wordPattern) {
            var changed = true
            var passes = 0
            while changed && passes < 5 {
                changed = false
                passes += 1
                let matches = regex.matches(in: current, range: NSRange(current.startIndex..., in: current))
                if let match = matches.first, let range = Range(match.range, in: current) {
                    let fullMatch = String(current[range])
                    let parts = fullMatch.components(separatedBy: .whitespaces)
                    if let first = parts.first, !emphaticAllowed.contains(first.lowercased()) {
                        current.replaceSubrange(range, with: first)
                        changed = true
                    }
                }
            }
        }

        return current
    }

    /// Removes stuttered syllable prefixes before the complete word (e.g. "dél délétère" -> "délétère", "pro problème" -> "problème").
    private func removeStutterPrefixes(in text: String) -> String {
        let stopWords: Set<String> = [
            "le", "la", "de", "du", "en", "un", "au", "ce", "se", "me", "te", "ne", "si", "ni", "ou",
            "et", "on", "ma", "ta", "sa", "in", "to", "at", "on", "by", "is", "it", "as", "an", "or",
            "so", "no", "my", "he", "we", "do", "go", "up", "me", "us", "des", "les", "ces", "mes",
            "tes", "ses", "nos", "vos", "ils", "par", "sur", "the", "and", "for", "are", "but", "not",
            "you", "all", "any", "can", "had", "her", "was", "one", "our", "out", "day", "get", "has",
            "him", "his", "how", "man", "new", "now", "old", "see", "two", "way", "who", "boy", "did",
            "its", "let", "put", "say", "she", "too", "use"
        ]

        let pattern = #"(?i)(?<![\p{L}0-9_'])([\p{L}]{2,4})\s+([\p{L}]+)(?![0-9\p{L}_'])"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }

        var current = text
        var changed = true
        var passes = 0
        while changed && passes < 5 {
            changed = false
            passes += 1
            let matches = regex.matches(in: current, range: NSRange(current.startIndex..., in: current))
            for match in matches {
                guard let range = Range(match.range, in: current),
                      let prefixRange = Range(match.range(at: 1), in: current),
                      let wordRange = Range(match.range(at: 2), in: current) else { continue }

                let prefix = String(current[prefixRange]).lowercased()
                let word = String(current[wordRange])
                let wordLower = word.lowercased()

                if wordLower.hasPrefix(prefix),
                   wordLower.count >= prefix.count + 2,
                   !stopWords.contains(prefix) {
                    current.replaceSubrange(range, with: word)
                    changed = true
                    break
                }
            }
        }

        return current
    }

    /// Inserts natural punctuation when speech has capitalized conversational transitions (e.g. "son Ouais" -> "son. Ouais").
    private func smoothConversationalTransitions(in text: String) -> String {
        let conversationalCues = [
            "Ouais", "Mec", "Alors", "Bref", "Bon", "Pourtant", "D'ailleurs", "Attends", "Regarde", "Écoute"
        ]
        var result = text
        for cue in conversationalCues {
            let pattern = "(?<=[a-zà-ÿ]) +(\(cue)\\b)"
            result = result.replacingOccurrences(of: pattern, with: ". $1", options: .regularExpression)
        }
        return result
    }
}

/// No-op formatter, for comparing raw engine output against the cleanup pass.
struct PassthroughFormatter: TextFormatter {
    func format(_ raw: String) async -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func format(_ raw: String, context: AppContextDetector.AppContext?) async -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
