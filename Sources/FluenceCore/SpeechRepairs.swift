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
        return reviseSameKind(result)
    }

    private static let revision = try? NSRegularExpression(
        pattern: #"(?i)\b([\p{L}0-9_]+)\s*(?:,\s*actually|,\s*en fait|\s+no wait|\s+make that|\s+i meant|\s+or actually|\s+non attends|\s+ou plutôt|\s+je voulais dire)\s+([\p{L}0-9_]+)\b"#
    )

    /// "mardi, en fait mercredi" → "mercredi", but only when both words are the same kind of
    /// thing — two numbers, two days, two months, two names. These cues are ordinary French
    /// and English the rest of the time: "c'était facile, en fait c'est compliqué" and "je
    /// voulais dire que…" are not corrections, and replacing the word before the cue there
    /// deleted what was said (FLU-27, measured in 8 clips out of 8).
    static func reviseSameKind(_ text: String) -> String {
        guard let revision else { return text }
        var result = text
        let matches = revision.matches(in: result, range: NSRange(result.startIndex..., in: result))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: result),
                  let old = Range(match.range(at: 1), in: result),
                  let new = Range(match.range(at: 2), in: result)
            else { continue }
            let startsSentence = result[..<old.lowerBound]
                .last(where: { !$0.isWhitespace })
                .map { ".!?\n".contains($0) } ?? true
            guard let kind = RevisionKind(String(result[old]), startsSentence: startsSentence),
                  kind == RevisionKind(String(result[new]), startsSentence: false)
            else { continue }
            result.replaceSubrange(whole, with: String(result[new]))
        }
        return result
    }

    /// What a word is, as far as a spoken self-correction cares.
    enum RevisionKind: Equatable {
        case number, weekday, month, name

        init?(_ word: String, startsSentence: Bool) {
            let lowered = word.lowercased()
            if Self.weekdays.contains(lowered) {
                self = .weekday
            } else if Self.months.contains(lowered) {
                self = .month
            } else if word.contains(where: \.isNumber) || Self.numberWords.contains(lowered) {
                self = .number
            } else if !startsSentence, word.first?.isUppercase == true {
                // A capital mid-sentence is a name; at a sentence start it says nothing.
                self = .name
            } else {
                return nil
            }
        }

        static let weekdays: Set<String> = [
            "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi", "dimanche",
            "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        ]
        static let months: Set<String> = [
            "janvier", "février", "fevrier", "mars", "avril", "mai", "juin", "juillet", "août",
            "aout", "septembre", "octobre", "novembre", "décembre", "decembre",
            "january", "february", "march", "april", "may", "june", "july", "august",
            "september", "october", "november", "december",
        ]
        static let numberWords: Set<String> = [
            "zéro", "zero", "un", "une", "deux", "trois", "quatre", "cinq", "six", "sept", "huit",
            "neuf", "dix", "onze", "douze", "treize", "quatorze", "quinze", "seize", "vingt",
            "trente", "quarante", "cinquante", "soixante", "cent", "mille",
            "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
            "eleven", "twelve", "fifteen", "twenty", "thirty", "forty", "fifty", "hundred",
            "thousand", "noon", "midnight", "midi", "minuit",
        ]
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

    /// Short words that are words, not the start of a stuttered one. A real stutter is a
    /// fragment ("pro problème"); a common word before a longer one that happens to start the
    /// same way is speech ("on va valider", "celui qui quitte", "il illustre", "be better"),
    /// and removing it deleted what was said (FLU-27, measured in 8 clips out of 8).
    static let stutterStopWords: Set<String> = [
        // French: articles, pronouns, prepositions, conjunctions.
        "le", "la", "les", "de", "du", "des", "un", "une", "au", "aux", "ce", "ces", "cet", "ça",
        "ci", "se", "me", "te", "ne", "si", "ni", "ou", "où", "et", "en", "on", "ma", "ta", "sa",
        "mes", "tes", "ses", "nos", "vos", "mon", "ton", "son", "je", "tu", "il", "ils", "elle",
        "nous", "vous", "eux", "lui", "leur", "moi", "toi", "soi", "que", "qui", "quoi", "quel",
        "dont", "par", "sur", "sous", "pour", "dans", "avec", "sans", "chez", "vers", "entre",
        "mais", "donc", "car", "puis", "lors", "dès", "pas", "plus", "bien", "tout", "tous",
        "très", "trop", "peu", "tant", "rien", "ici", "là", "oui", "non", "bon", "beau",
        // French: short verb forms said every day.
        "ai", "as", "est", "es", "ont", "été", "va", "vas", "vais", "vont", "fait", "fais",
        "font", "dit", "dis", "suis", "sont", "sera", "peut", "peux", "veut", "veux", "doit",
        "faut", "vu", "mis", "pris", "voir", "avez", "être",
        // French: numbers and units.
        "deux", "six", "sept", "huit", "neuf", "dix", "onze", "cent", "an", "ans", "mois",
        "jour", "fois", "fin", "mal", "bas", "haut", "part", "coup", "nom", "mot",
        // English.
        "in", "to", "at", "by", "is", "it", "as", "an", "or", "so", "no", "my", "he", "we", "do",
        "go", "up", "us", "be", "am", "if", "of", "on", "me", "the", "and", "for", "are", "but",
        "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out", "day",
        "get", "got", "has", "him", "his", "how", "man", "new", "now", "old", "see", "two",
        "way", "who", "boy", "did", "its", "let", "put", "say", "she", "too", "use", "off",
        "yes", "why", "few", "own", "set", "run", "end", "big", "top", "this", "that", "than",
        "then", "them", "they", "what", "when", "with", "will", "have", "been", "were", "from",
        "into", "just", "like", "make", "more", "most", "must", "only", "over", "said", "some",
        "such", "take", "very", "want", "well", "went", "your", "also", "back", "call", "come",
        "each", "even", "find", "give", "good", "here", "long", "look", "many", "much", "need",
        "next", "real", "same", "show", "sure", "tell", "time", "turn", "week", "year", "work",
        "know", "does", "done",
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
