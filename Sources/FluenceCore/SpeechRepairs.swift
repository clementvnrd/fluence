import Foundation

/// Clement's extra rules (his `RuleBasedFormatter`, FLU-11), around FluenceCore's
/// `RuleCleanup` at level Light: spoken cancellations and self-corrections, stutters and
/// repeated words, spoken lists, and — in developer tools — spoken code symbols and no full
/// stop after a one-line command.
///
/// For English and French (and Auto, which mixes them); other languages skip them, since
/// every rule here is written for those two.
public enum SpeechRepairs {
    /// Before `RuleCleanup`: what must happen on the words as spoken.
    public static func before(_ text: String, language: DictationLanguage) -> String {
        guard applies(to: language) else { return text }
        var result = text
        result = backtrack(result)
        result = deduplicateConsecutiveWords(in: result)
        result = removeStutterPrefixes(in: result)
        result = grammaticalCorrections(result)
        return result
    }

    /// After `RuleCleanup` (or the model): layout and developer formatting.
    ///
    /// - Parameter developer: the text is going into a code editor or a terminal and the
    ///   "Formatage code & terminaux" switch is on.
    public static func after(_ text: String, language: DictationLanguage, developer: Bool) -> String {
        guard applies(to: language) else { return text }
        var result = text
        if developer { result = developerSymbols(result) }
        let listed = smartLists(result)
        if listed != result {
            result = RuleCleanup.capitalizeSentences(RuleCleanup.collapseWhitespace(listed))
        }
        result = conversationalTransitions(result)
        if developer { result = suppressTrailingPeriod(result) }
        return result
    }

    static func applies(to language: DictationLanguage) -> Bool {
        language == .english || language == .french || language == .auto
    }

    // MARK: - Cancellations and self-corrections

    /// "… scratch that, …" keeps only what follows; "Tuesday, actually Wednesday" keeps the
    /// revised word.
    static func backtrack(_ text: String) -> String {
        var result = text
        if let scratch = result.range(
            of: #"(?i)\b(?:scratch that|delete that|efface tout|efface ça|annule tout|annule ça|supprime ça)\b"#,
            options: [.regularExpression, .backwards]
        ) {
            result = String(result[scratch.upperBound...])
                .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",.;:")))
        }
        let revision = #"(?i)\b([\p{L}0-9_]+)\s*(?:,\s*actually|,\s*en fait|\s+no wait|\s+make that|\s+i meant|\s+or actually|\s+non attends|\s+ou plutôt|\s+je voulais dire)\s+([\p{L}0-9_]+)\b"#
        return result.replacingOccurrences(of: revision, with: "$2", options: .regularExpression)
    }

    // MARK: - Repeated words and stutters

    /// Words that are legitimately said twice in a row.
    static let emphaticAllowed: Set<String> = [
        "très", "trop", "fort", "loin", "long", "jamais", "non", "oui", "bye", "merci",
        "very", "too", "so", "really", "no", "yes",
        // French reflexives: "nous nous sommes vus", "vous vous trompez".
        "nous", "vous",
    ]

    /// "c'est c'est" → "c'est", "il y a il y a" → "il y a", "the the" → "the".
    static func deduplicateConsecutiveWords(in text: String) -> String {
        var current = text
        let patterns = [
            #"(?i)(?<![\p{L}0-9_])([\p{L}]+['’]?[\p{L}]*(?:\s+[\p{L}]+['’]?[\p{L}]*){1,2})\s+\1(?![0-9\p{L}_])"#,
            #"(?i)(?<![\p{L}0-9_])([\p{L}]+['’][\p{L}]+)\s+\1(?![0-9\p{L}_])"#,
            #"(?i)(?<![\p{L}0-9_'])([\p{L}]+)\s+\1(?![0-9\p{L}_'])"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            var passes = 0
            var searchFrom = current.startIndex
            while passes < 8 {
                passes += 1
                let range = NSRange(searchFrom..<current.endIndex, in: current)
                guard let match = regex.firstMatch(in: current, range: range),
                      let whole = Range(match.range, in: current),
                      let first = Range(match.range(at: 1), in: current)
                else { break }
                let phrase = String(current[first])
                if emphaticAllowed.contains(phrase.lowercased()) {
                    searchFrom = first.upperBound
                    continue
                }
                current.replaceSubrange(whole, with: phrase)
                searchFrom = current.startIndex
            }
        }
        return current
    }

    /// Short words that are words, not the start of a stuttered one.
    static let stutterStopWords: Set<String> = [
        "le", "la", "de", "du", "en", "un", "au", "ce", "se", "me", "te", "ne", "si", "ni", "ou",
        "et", "on", "ma", "ta", "sa", "in", "to", "at", "by", "is", "it", "as", "an", "or",
        "so", "no", "my", "he", "we", "do", "go", "up", "us", "des", "les", "ces", "mes",
        "tes", "ses", "nos", "vos", "ils", "par", "sur", "the", "and", "for", "are", "but", "not",
        "you", "all", "any", "can", "had", "her", "was", "one", "our", "out", "day", "get", "has",
        "him", "his", "how", "man", "new", "now", "old", "see", "two", "way", "who", "boy", "did",
        "its", "let", "put", "say", "she", "too", "use",
        // French words that also start longer ones: "pas passé", "mon monde", "tout toutes".
        "pas", "mon", "ton", "son", "sans", "plus", "bien", "tout", "très", "pour", "dans", "avec",
    ]

    /// "pro problème" → "problème", "dél délétère" → "délétère".
    ///
    /// The full word is matched by lookahead, so "un pro problème" still finds "pro" after
    /// "un" has been looked at (Clement's version consumed it and missed the stutter).
    static func removeStutterPrefixes(in text: String) -> String {
        let pattern = #"(?i)(?<![\p{L}0-9_'])([\p{L}]{2,4})\s+(?=([\p{L}]+)(?![0-9\p{L}_']))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var current = text
        var passes = 0
        while passes < 8 {
            passes += 1
            var removed = false
            for match in regex.matches(in: current, range: NSRange(current.startIndex..., in: current)) {
                guard let range = Range(match.range, in: current),
                      let prefixRange = Range(match.range(at: 1), in: current),
                      let wordRange = Range(match.range(at: 2), in: current) else { continue }
                let prefix = current[prefixRange].lowercased()
                let word = current[wordRange].lowercased()
                if word.hasPrefix(prefix), word.count >= prefix.count + 2, !stutterStopWords.contains(prefix) {
                    current.removeSubrange(range)
                    removed = true
                    break
                }
            }
            if !removed { break }
        }
        return current
    }

    /// A misrecognition common enough to fix by rule: "les énormes œils" → "les énormes yeux".
    static func grammaticalCorrections(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)\b(les|des|mes|tes|ses|nos|vos|leurs|énormes|beaux|grands|petits)\s+œils\b"#,
            with: "$1 yeux",
            options: .regularExpression
        )
    }

    // MARK: - Lists

    /// Spoken bullets ("tiret", "puce", "bullet point") and ordinals ("premièrement",
    /// "secondly", "numéro deux") become list lines.
    static func smartLists(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: #"(?i)(^|[,.;:!?\n]\s*)(?:bullet\s+points?|boulettes?\s+de\s+pot|tiret|puce)\s*,?\s*"#,
            with: "\n- ",
            options: .regularExpression
        )
        let ordinals: [(String, String)] = [
            ("premièrement|en premier", "1"),
            ("deuxièmement|en deuxième", "2"),
            ("troisièmement|en troisième", "3"),
            ("quatrièmement|en quatrième", "4"),
            ("cinquièmement|en cinquième", "5"),
            ("firstly|first of all", "1"),
            ("secondly|second of all", "2"),
            ("thirdly", "3"),
        ]
        for (spoken, number) in ordinals {
            result = result.replacingOccurrences(
                of: "(?i)(^|[,.;:!?\\n]\\s*)(?:donc\\s+)?(?:\(spoken))\\s*,?\\s*",
                with: "\n\(number). ",
                options: .regularExpression
            )
        }
        result = result.replacingOccurrences(
            of: #"(?i)(?:^|(?<=[.!?\n]\s{0,3}))(?:number|numéro)\s+(\d+)\s+"#,
            with: "\n$1. ",
            options: .regularExpression
        )
        let numberWords: [(String, String)] = [
            ("one", "1"), ("two", "2"), ("three", "3"), ("four", "4"), ("five", "5"),
            ("un", "1"), ("deux", "2"), ("trois", "3"), ("quatre", "4"), ("cinq", "5"),
        ]
        for (word, digit) in numberWords {
            result = result.replacingOccurrences(
                of: "(?i)(?:^|(?<=[.!?\\n]\\s{0,3}))(?:number|numéro)\\s+\(word)\\s+",
                with: "\n\(digit). ",
                options: .regularExpression
            )
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "son Ouais" → "son. Ouais": a capitalised conversational cue mid-sentence starts one.
    static func conversationalTransitions(_ text: String) -> String {
        let cues = ["Ouais", "Mec", "Alors", "Bref", "Bon", "Pourtant", "D'ailleurs", "Attends", "Regarde", "Écoute"]
        var result = text
        for cue in cues {
            result = result.replacingOccurrences(
                of: "(?<=[a-zà-ÿ]) +(\(cue)\\b)",
                with: ". $1",
                options: .regularExpression
            )
        }
        return result
    }

    // MARK: - Developer tools

    static func developerSymbols(_ text: String) -> String {
        var result = text.replacingOccurrences(
            of: #"(?i)\b(?:double tiret|tiret tiret|dash dash)\s+([a-zA-Z0-9_\-]+)\b"#,
            with: "--$1",
            options: .regularExpression
        )
        result = result.replacingOccurrences(
            of: #"(?i)\b(?:tiret simple|single dash)\s+([a-zA-Z0-9_\-]+)\b"#,
            with: "-$1",
            options: .regularExpression
        )
        let symbols: [(String, String)] = [
            ("accolade ouvrante", "{"), ("accolade fermante", "}"),
            ("crochet ouvrant", "["), ("crochet fermant", "]"),
            ("anti slash", "\\\\"), ("point barre", "/"),
            ("égal égal", "=="), ("différent de", "!="),
            ("flèche droite", "->"), ("grosse flèche", "=>"),
        ]
        for (spoken, symbol) in symbols {
            result = result.replacingOccurrences(
                of: "(?i)\\b\(spoken)\\b",
                with: symbol,
                options: .regularExpression
            )
        }
        return result
    }

    /// `brew install ripgrep`, not `Brew install ripgrep.`: one line, one sentence, no stop.
    static func suppressTrailingPeriod(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix("."), !trimmed.hasSuffix(".."),
              !trimmed.contains("\n"), !trimmed.dropLast().contains(". ")
        else { return trimmed }
        return String(trimmed.dropLast())
    }
}

// MARK: - Developer tools

/// The editors and terminals where Clement's code formatting applies (his
/// `AppContextDetector`'s developer list).
public enum DeveloperTools {
    static let bundleIDs: Set<String> = [
        "com.microsoft.vscode",
        "com.microsoft.vscodeinsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "com.apple.dt.xcode",
        "com.apple.terminal",
        "com.googlecode.iterm2",
        "dev.warp.warp-stable",
        "com.mitchellh.ghostty",
        "io.alacritty",
        "net.kovidgoyal.kitty",
        "dev.zed.zed",
        "com.sublimetext.4",
        "com.jetbrains.intellij",
        "com.jetbrains.pycharm",
        "com.jetbrains.webstorm",
    ]

    public static func contains(bundleID: String?) -> Bool {
        guard let bundleID = bundleID?.lowercased() else { return false }
        return bundleIDs.contains(bundleID)
    }
}
