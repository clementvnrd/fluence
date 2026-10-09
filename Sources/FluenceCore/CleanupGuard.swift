import Foundation

/// Decides whether a model's "cleaned" transcript is recognizably the user's own words.
///
/// The failure this defends against is real and was reproduced during development: dictate
/// "what is the capital of france" and the model helpfully returns "The capital of France is
/// Paris." — which would then be typed into the user's document.
///
/// The load-bearing check is **novel content words**, not length. Cleanup is a subtractive
/// operation: it deletes fillers, fixes punctuation, and applies spoken corrections. It has
/// essentially no reason to introduce a content word that wasn't spoken. "Paris" never
/// appears in the input, so it's the tell.
///
/// Measured against the development cases: legitimate filler-heavy cleanup introduces zero
/// novel content words, while an answered question introduces at least one.
public enum CleanupGuard {
    public enum Verdict: Equatable, Sendable {
        case accepted
        case empty
        /// How many content words appear in the output but were never spoken. A count, so
        /// the reason can be logged without logging the user's words.
        case inventedWords(Int)
        case lengthRatio(Double)
        case commentary
    }

    /// Below this, the cleanup dropped too much of what was said. Real cleanups measure
    /// 0.6–1.0 against the filler-discounted input; at the previous 0.35 a model could lose
    /// two thirds of a dictation and still be accepted.
    public static let minimumRatio = 0.6
    public static let maximumRatio = 1.5

    /// - Parameters:
    ///   - language: the transcript's language. French brings its own articles, elisions,
    ///     fillers and number words; any other language is judged with the English lists.
    ///   - restyled: the output was also rewritten in a writing style (cleanup level High).
    ///     A style legitimately swaps grammatical words — "do not" for "don't", "vous" for
    ///     "tu" — so those stop counting as inventions. Content words still do, which is what
    ///     catches an answered question.
    public static func evaluate(
        original: String,
        cleaned: String,
        language: DictationLanguage = .english,
        restyled: Bool = false
    ) -> Verdict {
        guard !cleaned.isEmpty else { return .empty }

        let french = language == .french
        var stopWords = Self.stopWords
        if french { stopWords.formUnion(frenchStopWords) }
        if restyled { stopWords.formUnion(french ? frenchRestyleWords : englishRestyleWords) }
        let fillerWords = french ? Self.fillerWords.union(frenchFillerWords) : Self.fillerWords

        let originalTokens = tokens(original, french: french)
        let cleanedTokens = tokens(cleaned, french: french)
        let originalWords = originalTokens.filter { !stopWords.contains($0) }
        let cleanedWords = cleanedTokens.filter { !stopWords.contains($0) }
        guard !originalWords.isEmpty else { return .empty }

        // 1. Content words nobody said. A single one shows the model answered
        //    rather than transformed. Numbers are compared as values, so "three" → "3" and
        //    "twenty twenty six" → "2026" are the same word, not an invention.
        let vocabulary = Set(originalWords).union(numberRuns(in: originalTokens))
        let invented = inventedCount(cleanedTokens, vocabulary: vocabulary, stopWords: stopWords)
        guard invented == 0 else { return .inventedWords(invented) }

        // 2. Length, as a backstop to check 1 for a model that carries out a dictated
        //    instruction using only words from the input ("write the word banana" → "Banana"),
        //    and for a cleanup that quietly drops sentences.
        //
        //    The ratio is taken on the input minus its fillers. On the raw input, a dictation
        //    that lost half its words cannot be told from "a dictation that was mostly filler and
        //    was legitimately cut in half". Discounting fillers on both sides pushes the real
        //    cleanups to 0.6–1.0 and leaves the failures below 0.2.
        //
        //    A run of numbers counts once on each side: "five five five one two three four"
        //    and "555-1234" are the same amount of speech.
        let spoken = collapsingNumberRuns(originalWords).count { !fillerWords.contains($0) }
        let ratio = Double(collapsingNumberRuns(cleanedWords).count) / Double(max(1, spoken))
        guard ratio >= minimumRatio, ratio <= maximumRatio else { return .lengthRatio(ratio) }

        // 3. A model that starts explaining itself has stopped being a text processor —
        //    unless the speaker started that way too ("Sure, I can do Tuesday").
        let lowered = cleaned.lowercased()
        let spokenStart = original.lowercased().trimmingCharacters(in: .whitespaces)
        let tells = french ? Self.tells + frenchTells : Self.tells
        let explains = tells.contains { lowered.hasPrefix($0) && !spokenStart.hasPrefix(String($0.prefix { $0.isLetter || $0 == " " || $0 == "'" })) }
        return explains ? .commentary : .accepted
    }

    // MARK: - Tokens

    /// Lowercased alphanumeric words with spoken numbers turned into digits. Contractions are
    /// split so "isn't" matches "isn t"; thousands separators are dropped so "1,000" is one
    /// number.
    static func tokens(_ text: String, french: Bool = false) -> [String] {
        let joined = text.lowercased().replacingOccurrences(
            of: #"(?<=\d),(?=\d{3}(?!\d))"#,
            with: "",
            options: .regularExpression
        )
        let words = joined.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return french ? FrenchNumberWords.canonical(words) : NumberWords.canonical(words)
    }

    /// Concatenations of adjacent numbers as spoken: "nineteen eighty four" is [19, 84], and
    /// a cleanup writing "1984" has invented nothing. Same for digit-by-digit phone numbers.
    static func numberRuns(in tokens: [String], longest: Int = 6) -> Set<String> {
        var runs: Set<String> = []
        for start in tokens.indices where tokens[start].allSatisfy(\.isNumber) {
            var joined = ""
            for index in start..<min(tokens.count, start + longest) {
                guard tokens[index].allSatisfy(\.isNumber) else { break }
                joined += tokens[index]
                runs.insert(joined)
            }
        }
        return runs
    }

    private static func collapsingNumberRuns(_ tokens: [String]) -> [String] {
        var out: [String] = []
        for token in tokens {
            let isNumber = token.allSatisfy(\.isNumber)
            if isNumber, let last = out.last, last.allSatisfy(\.isNumber) { continue }
            out.append(token)
        }
        return out
    }

    /// Counts cleaned words that were never spoken. A run of numbers in the output is also
    /// accepted when it spells, concatenated, a number that *was* spoken ("2026" said, "20 26"
    /// written).
    private static func inventedCount(_ tokens: [String], vocabulary: Set<String>, stopWords: Set<String>) -> Int {
        var invented = 0
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token.allSatisfy(\.isNumber) {
                var end = index
                while end < tokens.count, tokens[end].allSatisfy(\.isNumber) { end += 1 }
                let run = tokens[index..<end]
                if !vocabulary.contains(run.joined()) {
                    invented += run.count { !vocabulary.contains($0) }
                }
                index = end
                continue
            }
            if !stopWords.contains(token), !vocabulary.contains(token) { invented += 1 }
            index += 1
        }
        return invented
    }

    // MARK: - Word lists

    /// Small on purpose: each word here escapes the invented-word check, so it only holds words
    /// that re-punctuating a transcript may rightly add or remove.
    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "then", "s", "t", "re", "ll", "ve", "d", "m",
    ]

    /// Wider than the rule formatter's filler list, on purpose. The set never takes a word out of
    /// the user's text, it only lowers the count the ratio divides by, so it can
    /// afford to be aggressive about discourse markers the model legitimately deletes,
    /// including the ones that introduce a spoken self-correction ("three, no wait, four").
    static let fillerWords: Set<String> = [
        "actually", "anyway", "basically", "erm", "hmm", "i", "just", "know", "like", "literally",
        "mean", "mhm", "ok", "okay", "really", "right", "uh", "uhm", "um", "well", "you",
        "kind", "sort", "of", "stuff", "thing", "things", "no", "wait", "sorry", "oops", "scratch",
    ]

    private static let tells = [
        "as an ai", "certainly,", "cleaned transcript", "here is the cleaned", "here's the cleaned",
        "i can't", "i cannot", "sure,",
    ]

    // MARK: - French

    /// Articles, elided pronouns and conjunctions a French cleanup re-punctuating "j ai" into
    /// "j'ai", or "c est" into "c'est", may insert or drop.
    static let frenchStopWords: Set<String> = [
        "le", "la", "les", "l", "de", "d", "du", "des", "un", "une", "et", "ou", "mais", "donc",
        "que", "qu", "à", "au", "aux", "en", "y", "j", "n", "s", "c", "m", "t", "ne",
    ]

    /// Hesitations and discourse markers a French cleanup legitimately deletes, including
    /// the ones that announce a self-correction ("trois, non, enfin quatre").
    static let frenchFillerWords: Set<String> = [
        "euh", "heu", "hum", "hmm", "bah", "ben", "genre", "bon", "alors", "voilà", "voila",
        "enfin", "pardon", "non", "plutôt", "fait", "coup", "du", "quoi", "hein", "tu", "vois",
        "sais", "disons", "attends", "attendez", "ouais", "oups", "en",
    ]

    private static let frenchTells = [
        "voici le texte", "voici la transcription", "texte nettoyé", "transcription nettoyée",
        "bien sûr,", "certainement,", "je ne peux pas", "en tant qu'ia", "en tant qu’ia",
    ]

    // MARK: - Restyling (level High)

    /// Grammatical words a change of register swaps in or out. No nouns, verbs of substance
    /// or numbers: those still have to have been said.
    static let englishRestyleWords: Set<String> = [
        "is", "are", "am", "was", "were", "be", "been", "will", "would", "shall", "should",
        "not", "do", "does", "did", "have", "has", "had", "can", "cannot", "could", "may",
        "might", "i", "you", "we", "it", "they", "he", "she", "me", "us", "them", "my", "your",
        "our", "to", "of", "for", "with", "that", "this", "these", "those", "there", "in", "on",
        "at", "as",
    ]

    static let frenchRestyleWords: Set<String> = frenchStopWords.union([
        "vous", "tu", "te", "toi", "votre", "vos", "ton", "ta", "tes", "pas", "est", "sont",
        "suis", "es", "ai", "as", "avez", "avons", "a", "je", "nous", "il", "elle", "on", "ce",
        "ça", "cela", "pour", "se", "me", "moi", "lui", "leur", "leurs",
    ])
}

/// Spoken numbers to digits, just well enough to compare a transcript with its cleanup.
///
/// Not a general parser: it has to agree with itself on both sides of the comparison, and
/// to recognise what a cleanup pass writes for what was said — cardinals, ordinals, years
/// said in pairs, "and" inside a number, a digit followed by a scale ("5 million").
enum NumberWords {
    static func canonical(_ words: [String]) -> [String] {
        var out: [String] = []
        var index = 0
        while index < words.count {
            if let number = parse(words, from: index) {
                out.append(number.text)
                index += number.consumed
            } else {
                out.append(words[index])
                index += 1
            }
        }
        return out
    }

    private enum Part { case start, unit, teen, tens, hundred, scale, digits }

    private static func parse(_ words: [String], from start: Int) -> (text: String, consumed: Int)? {
        var total = 0
        var current = 0
        var last = Part.start
        var ordinal = false
        var index = start

        while index < words.count, !ordinal {
            let word = words[index]

            if word == "and", last == .hundred || last == .scale,
               index + 1 < words.count, small(words[index + 1]) != nil || tens(words[index + 1]) != nil {
                index += 1
                continue
            }

            if let (value, isOrdinal) = small(word) {
                let fits = value < 10
                    ? [.start, .tens, .hundred, .scale].contains(last)
                    : [.start, .hundred, .scale].contains(last)
                guard fits, value != 0 || last == .start else { break }
                current += value
                last = value < 10 ? .unit : .teen
                ordinal = isOrdinal
                if value == 0 { index += 1; break }
            } else if let (value, isOrdinal) = tens(word) {
                guard [.start, .hundred, .scale].contains(last) else { break }
                current += value
                last = .tens
                ordinal = isOrdinal
            } else if word == "hundred" || word == "hundredth" {
                guard [.start, .unit, .teen, .tens, .digits].contains(last), current < 100 else { break }
                current = max(current, 1) * 100
                last = .hundred
                ordinal = word == "hundredth"
            } else if let scale = scales[word] {
                guard last != .scale else { break }
                total += max(current, 1) * scale.value
                current = 0
                last = .scale
                ordinal = scale.isOrdinal
            } else if last == .start, let value = Int(word), index + 1 < words.count,
                      words[index + 1] == "hundred" || scales[words[index + 1]] != nil {
                // "5 million", "3 hundred": digits that a scale word goes on to multiply.
                current = value
                last = .digits
            } else {
                break
            }
            index += 1
        }

        guard index > start, last != .digits else { return nil }
        let value = total + current
        return (ordinal ? ordinalText(value) : String(value), index - start)
    }

    private static func small(_ word: String) -> (Int, Bool)? {
        if let value = cardinals[word] { return (value, false) }
        if let value = ordinals[word] { return (value, true) }
        return nil
    }

    private static func tens(_ word: String) -> (Int, Bool)? {
        if let value = tensCardinals[word] { return (value, false) }
        if let value = tensOrdinals[word] { return (value, true) }
        return nil
    }

    private static func ordinalText(_ value: Int) -> String {
        let suffix: String
        switch (value % 100, value % 10) {
        case (11...13, _): suffix = "th"
        case (_, 1): suffix = "st"
        case (_, 2): suffix = "nd"
        case (_, 3): suffix = "rd"
        default: suffix = "th"
        }
        return "\(value)\(suffix)"
    }

    private static let cardinals: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19,
    ]

    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7,
        "eighth": 8, "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13,
        "fourteenth": 14, "fifteenth": 15, "sixteenth": 16, "seventeenth": 17,
        "eighteenth": 18, "nineteenth": 19,
    ]

    private static let tensCardinals: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70,
        "eighty": 80, "ninety": 90,
    ]

    private static let tensOrdinals: [String: Int] = [
        "twentieth": 20, "thirtieth": 30, "fortieth": 40, "fiftieth": 50, "sixtieth": 60,
        "seventieth": 70, "eightieth": 80, "ninetieth": 90,
    ]

    private static let scales: [String: (value: Int, isOrdinal: Bool)] = [
        "thousand": (1_000, false), "thousandth": (1_000, true),
        "million": (1_000_000, false), "millionth": (1_000_000, true),
        "billion": (1_000_000_000, false), "billionth": (1_000_000_000, true),
    ]
}
