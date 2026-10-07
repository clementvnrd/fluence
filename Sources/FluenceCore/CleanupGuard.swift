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

    public static func evaluate(original: String, cleaned: String) -> Verdict {
        guard !cleaned.isEmpty else { return .empty }

        let originalTokens = tokens(original)
        let cleanedTokens = tokens(cleaned)
        let originalWords = originalTokens.filter { !stopWords.contains($0) }
        let cleanedWords = cleanedTokens.filter { !stopWords.contains($0) }
        guard !originalWords.isEmpty else { return .empty }

        // 1. No invented content. The single strongest signal that the model answered
        //    rather than transformed. Numbers are compared as values, so "three" → "3" and
        //    "twenty twenty six" → "2026" are the same word, not an invention.
        let vocabulary = Set(originalWords).union(numberRuns(in: originalTokens))
        let invented = inventedCount(cleanedTokens, vocabulary: vocabulary)
        guard invented == 0 else { return .inventedWords(invented) }

        // 2. Length sanity, as a backstop for the case where the model obeys an injected
        //    instruction using only words from the input ("write the word banana" → "Banana"),
        //    and for a cleanup that quietly drops sentences.
        //
        //    Measured against the *filler-discounted* input, not the raw one. A raw ratio
        //    conflates "the model truncated my sentence" with "the input was 80% filler and
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
        let explains = tells.contains { lowered.hasPrefix($0) && !spokenStart.hasPrefix(String($0.prefix { $0.isLetter || $0 == " " || $0 == "'" })) }
        return explains ? .commentary : .accepted
    }

    // MARK: - Tokens

    /// Lowercased alphanumeric words with spoken numbers turned into digits. Contractions are
    /// split so "isn't" matches "isn t"; thousands separators are dropped so "1,000" is one
    /// number.
    static func tokens(_ text: String) -> [String] {
        let joined = text.lowercased().replacingOccurrences(
            of: #"(?<=\d),(?=\d{3}(?!\d))"#,
            with: "",
            options: .regularExpression
        )
        let words = joined.split { !$0.isLetter && !$0.isNumber }.map(String.init)
        return NumberWords.canonical(words)
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
    private static func inventedCount(_ tokens: [String], vocabulary: Set<String>) -> Int {
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

    /// Deliberately small. Every word here is one the guard stops policing, so it only
    /// covers words a cleanup pass may genuinely insert or drop while re-punctuating.
    static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "so", "then", "s", "t", "re", "ll", "ve", "d", "m",
    ]

    /// Broader than `RuleBasedFormatter`'s strip list on purpose. This set only affects the
    /// guard's denominator — it never removes anything from the user's text — so it can
    /// afford to be aggressive about discourse markers the model legitimately deletes,
    /// including the ones that introduce a spoken self-correction ("three, no wait, four").
    static let fillerWords: Set<String> = [
        "um", "uh", "erm", "uhm", "hmm", "mhm", "like", "basically", "actually", "literally",
        "just", "really", "okay", "ok", "well", "right", "anyway", "i", "mean", "you", "know",
        "kind", "sort", "of", "stuff", "thing", "things", "no", "wait", "sorry", "oops", "scratch",
    ]

    private static let tells = [
        "here's the cleaned", "here is the cleaned", "cleaned transcript",
        "sure,", "certainly,", "i cannot", "i can't", "as an ai",
    ]
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
