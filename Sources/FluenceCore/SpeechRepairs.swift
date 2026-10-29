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
    ///
    /// Code formatting (symbols, no final stop) applies only to text that looks like a command
    /// — no French function word once the spoken symbols are set aside — or that opens with
    /// the spoken prefix « code : ». French prose typed into a terminal (a prompt to Claude
    /// Code) is prose: « différent de ce qu'on attendait » is not « != » (FLU-30).
    public static func after(_ text: String, language: DictationLanguage, developer: Bool) -> String {
        guard applies(to: language) else { return text }
        if developer, let code = afterCodePrefix(text) {
            return suppressTrailingPeriod(developerSymbols(code))
        }
        let formatsCode = developer && looksLikeCommand(text)
        var result = text
        if formatsCode { result = developerSymbols(result) }
        let listed = smartLists(result)
        if listed != result {
            result = RuleCleanup.capitalizeSentences(RuleCleanup.collapseWhitespace(listed))
        }
        result = conversationalTransitions(result)
        if formatsCode { result = suppressTrailingPeriod(result) }
        return result
    }

    static func applies(to language: DictationLanguage) -> Bool {
        language == .english || language == .french || language == .auto
    }

    // MARK: - Cancellations and self-corrections

    /// "… scratch that, …" keeps only what follows; "Tuesday, actually Wednesday" keeps the
    /// revised word.
    ///
    /// The French cancels are ordinary French (« supprime ça et on recommence demain », « Si le
    /// déploiement plante, annule tout. »), and deleting the dictation around them lost it
    /// (FLU-87, FLU-124). They are a command only as the whole dictation, a filler and marks
    /// aside: the dictation is dropped.
    static func backtrack(_ text: String) -> String {
        if text.range(
            of: #"(?i)^[\s,.;:!?…]*(?:(?:euh|heu|hum)[\s,.]+)?(?:efface tout|efface ça|annule tout|annule ça|supprime ça)[\s.!…]*$"#,
            options: .regularExpression
        ) != nil {
            return ""
        }
        var result = text
        if let scratch = result.range(
            of: #"(?i)\b(?:scratch that|delete that)\b"#,
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
            // A question asks, it does not correct: « Slack ou plutôt Teams pour le client ? »
            if result[whole.upperBound...].first(where: { ".!?\n".contains($0) }) == "?" { continue }
            // A sentence goes on from a number or a name (« trois, en fait deux sont cassés »,
            // « Paul, en fait Marie l'a vu »); a correction ends there, or with a unit (FLU-124).
            if kind == .number || kind == .name, !endsCorrection(result[whole.upperBound...]) { continue }
            result.replaceSubrange(whole, with: String(result[new]))
        }
        return result
    }

    /// Units a corrected amount may carry: « 300 non attends 400 euros ».
    static let units: Set<String> = [
        "€", "euro", "euros", "$", "dollar", "dollars", "%", "h", "heure", "heures", "min", "minute",
        "minutes", "jour", "jours", "semaine", "semaines", "mois", "an", "ans", "km", "mètres",
        "kilos", "hours", "days", "weeks",
    ]

    /// Whether a corrected word ends the correction: the end, a mark, or a unit after it.
    private static func endsCorrection(_ rest: Substring) -> Bool {
        let rest = rest.drop(while: { $0 == " " })
        guard let first = rest.first, !",.;:!?…\n".contains(first) else { return true }
        return units.contains(rest.prefix { !$0.isWhitespace && !",.;:!?…".contains($0) }.lowercased())
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
        // « si si », « oh là là », « allez allez » (FLU-90).
        "si", "là", "vite", "allez", "bon", "bien", "encore", "vraiment",
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
        // Tech words heard in French (FLU-90): « le mail mailing », « data dataset ».
        "mail", "data", "app", "code", "file", "test", "web", "site", "page", "link", "text",
        "team", "chat", "note", "list", "user", "base", "bug", "log", "dev", "api", "tag", "push",
        "pull",
    ]

    /// "pro problème" → "problème", "dél délétère" → "délétère", and a word cut off with a
    /// hyphen even when it is a real one: "mail- mailing" → "mailing".
    ///
    /// The full word is matched by lookahead, so "un pro problème" still finds "pro" after
    /// "un" has been looked at (Clement's version consumed it and missed the stutter).
    static func removeStutterPrefixes(in text: String) -> String {
        let pattern = #"(?i)(?<![\p{L}0-9_'])([\p{L}]{2,4})(-?)\s+(?=([\p{L}]+)(?![0-9\p{L}_']))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        var current = text
        var passes = 0
        while passes < 8 {
            passes += 1
            var removed = false
            for match in regex.matches(in: current, range: NSRange(current.startIndex..., in: current)) {
                guard let range = Range(match.range, in: current),
                      let prefixRange = Range(match.range(at: 1), in: current),
                      let wordRange = Range(match.range(at: 3), in: current) else { continue }
                let prefix = current[prefixRange].lowercased()
                let word = current[wordRange].lowercased()
                let cutOff = match.range(at: 2).length > 0
                if word.hasPrefix(prefix), word.count >= prefix.count + 2, cutOff || !stutterStopWords.contains(prefix) {
                    current.removeSubrange(range)
                    removed = true
                    break
                }
            }
            if !removed { break }
        }
        return current
    }

    /// Misrecognitions common enough to fix by rule, each one never correct French as heard:
    /// "les énormes œils" → "les énormes yeux"; "mis à genre" → "mis à jour" (FLU-84: Parakeet
    /// hears « jour » as « genre » after *mettre*; « genre » elsewhere is left alone).
    static func grammaticalCorrections(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"(?i)\b(les|des|mes|tes|ses|nos|vos|leurs|énormes|beaux|grands|petits)\s+œils\b"#,
            with: "$1 yeux",
            options: .regularExpression
        )
        .replacingOccurrences(
            of: #"(?i)(?<![\p{L}0-9_])((?:re)?(?:mett\p{L}*|mets|met|mis|mise|mises))\s+[àa]\s+genre(?![\p{L}0-9_])"#,
            with: "$1 à jour",
            options: .regularExpression
        )
        // « soit » heard as « seit » before an English word (FLU-122); « seit » is no French word.
        .replacingOccurrences(of: #"(?<![\p{L}0-9_])([sS])eit(?![\p{L}0-9_])"#, with: "$1oit", options: .regularExpression)
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
        // « En premier lieu », « en deuxième position »: a set phrase, not a list item (FLU-30).
        let notSetPhrase = #"(?!\s+(?:lieu|temps|plan|ressort|rang|position|choix|niveau|ligne)\b)"#
        let ordinals: [(String, String)] = [
            ("premièrement|en premier\(notSetPhrase)", "1"),
            ("deuxièmement|en deuxième\(notSetPhrase)", "2"),
            ("troisièmement|en troisième\(notSetPhrase)", "3"),
            ("quatrièmement|en quatrième\(notSetPhrase)", "4"),
            ("cinquièmement|en cinquième\(notSetPhrase)", "5"),
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

    /// The spoken symbols, as `developerSymbols` writes them.
    static let spokenSymbols: [(String, String)] = [
        ("accolade ouvrante", "{"), ("accolade fermante", "}"),
        ("crochet ouvrant", "["), ("crochet fermant", "]"),
        ("anti slash", "\\\\"), ("point barre", "/"),
        ("égal égal", "=="), ("différent de", "!="),
        ("flèche droite", "->"), ("grosse flèche", "=>"),
    ]

    /// Words that only French prose has: articles, pronouns, prepositions, conjunctions,
    /// « être » and « avoir ». A single letter is left out (« a » is also a variable).
    static let frenchFunctionWords: Set<String> = [
        "le", "la", "les", "un", "une", "des", "du", "de", "au", "aux", "ce", "cet", "cette", "ces",
        "ça", "cela", "je", "tu", "il", "elle", "on", "nous", "vous", "ils", "elles", "me", "te",
        "se", "moi", "toi", "lui", "leur", "leurs", "mon", "ma", "mes", "ton", "ta", "tes", "son",
        "sa", "ses", "notre", "votre", "nos", "vos", "que", "qui", "quoi", "dont", "où", "et", "ou",
        "mais", "donc", "car", "puis", "ne", "pas", "plus", "est", "sont", "suis", "es", "était",
        "sera", "ai", "as", "ont", "avec", "pour", "dans", "sur", "sous", "chez", "sans", "vers",
        "par", "comme", "quand", "très", "aussi", "à", "en", "si", "y",
    ]
    /// Elisions: « qu'on », « l'erreur », « c'est ».
    static let frenchElisions: Set<String> = ["qu", "l", "d", "j", "c", "n", "s", "m", "t", "jusqu", "lorsqu", "puisqu"]

    /// Whether the text reads as a command rather than French prose.
    static func looksLikeCommand(_ text: String) -> Bool {
        var rest = text.lowercased()
        for (spoken, _) in spokenSymbols {
            rest = rest.replacingOccurrences(of: "\\b\(spoken)\\b", with: " ", options: .regularExpression)
        }
        let tokens = rest.split(whereSeparator: { !($0.isLetter || $0 == "'" || $0 == "’") })
        for token in tokens {
            let parts = token.split(whereSeparator: { $0 == "'" || $0 == "’" })
            if token.contains(where: { $0 == "'" || $0 == "’" }),
               let first = parts.first, frenchElisions.contains(String(first)) {
                return false
            }
            if frenchFunctionWords.contains(String(token)) { return false }
        }
        return true
    }

    /// The text after a spoken « code : » (« code deux points » when no rule made it a
    /// colon), or nil when it does not open with it.
    static func afterCodePrefix(_ text: String) -> String? {
        guard let prefix = text.range(
            of: "^\\s*code[ \u{00A0}\u{202F}]*(?::|deux points)\\s*",
            options: [.regularExpression, .caseInsensitive]
        ) else { return nil }
        let code = String(text[prefix.upperBound...])
        return code.isEmpty ? nil : code
    }

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
        for (spoken, symbol) in spokenSymbols {
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
