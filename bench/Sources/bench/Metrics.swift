import Foundation

// Accuracy and speed arithmetic for the bench. Nothing here touches audio or engines, so
// a mistake in scoring can never be mistaken for an engine failure: `run` only calls in
// here once both transcriptions are finished.

enum Scoring {

    // MARK: Normalisation

    /// Puts a transcript in the shape both scores compare: lower case, letters/marks/digits
    /// and the straight apostrophe kept, everything else turned into a gap, gaps collapsed
    /// to one space. Apple punctuates on its own while a hand-typed reference usually does
    /// not, so comparing raw text would count every comma as a mistake.
    ///
    /// The plain `'` survives so « don't » stays a single word; the curly one (U+2019) and
    /// hyphens do not, hence « re-run » scores as two words. Accents are kept, digits are
    /// not spelled out.
    static func normalise(_ text: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            let isWordPart = CharacterSet.alphanumerics.contains(scalar) || scalar == "'"
            kept.append(isWordPart ? scalar : " ")
        }
        return String(kept).split(separator: " ").joined(separator: " ")
    }

    static func words(of normalised: String) -> [String] {
        normalised.split(separator: " ").map(String.init)
    }

    // MARK: Edit distance

    /// Unit-cost Levenshtein distance (insert, delete and replace each cost 1), kept to two
    /// rows of the table since only the final number is needed.
    static func editDistance<Item: Equatable>(_ source: [Item], _ target: [Item]) -> Int {
        if source.isEmpty { return target.count }
        if target.isEmpty { return source.count }
        var previous = Array(0...target.count)
        var current = [Int](repeating: 0, count: target.count + 1)
        for row in 1...source.count {
            current[0] = row
            for column in 1...target.count {
                let replace = previous[column - 1] + (source[row - 1] == target[column - 1] ? 0 : 1)
                current[column] = min(previous[column] + 1, current[column - 1] + 1, replace)
            }
            swap(&previous, &current)
        }
        return previous[target.count]
    }

    // MARK: Rates

    /// Word error rate as a fraction (0.042 is 4.2 %). It may go past 1 when the engine
    /// adds many words. `nil`, not zero, when the reference has no word left after
    /// normalisation: there is nothing to score against.
    static func wordErrorRate(reference: String, hypothesis: String) -> Double? {
        let expected = words(of: normalise(reference))
        guard !expected.isEmpty else { return nil }
        let heard = words(of: normalise(hypothesis))
        return Double(editDistance(expected, heard)) / Double(expected.count)
    }

    /// Character error rate over the normalised strings, spaces counted, one unit per
    /// grapheme. It exists because the word rate punishes a jargon word missed by a single
    /// letter as harshly as a word missed entirely.
    static func characterErrorRate(reference: String, hypothesis: String) -> Double? {
        let expected = Array(normalise(reference))
        guard !expected.isEmpty else { return nil }
        let heard = Array(normalise(hypothesis))
        return Double(editDistance(expected, heard)) / Double(expected.count)
    }

    /// Audio seconds processed per wall-clock second; bigger is quicker. At 100 a
    /// one-minute clip is done in 0.6 s. The floor on the divisor avoids a division by zero
    /// on an instant (or failed-to-measure) run.
    static func realtimeFactor(audioSeconds: Double, processSeconds: Double) -> Double {
        audioSeconds / max(processSeconds, 0.0001)
    }

    // MARK: Alignment for the report

    enum TokenKind: Equatable {
        case match
        case substitution(expected: String)
        case insertion
        case deletion
    }

    struct Token: Equatable {
        let word: String
        let kind: TokenKind
    }

    /// Lines the heard words up against the reference so the report can colour each one.
    /// Words are the normalised ones (lower case, no punctuation). With no reference word
    /// at all, everything heard counts as matching.
    static func align(referenceWords expected: [String], hypothesisWords heard: [String]) -> [Token] {
        if expected.isEmpty {
            return heard.map { Token(word: $0, kind: .match) }
        }
        let rows = expected.count
        let columns = heard.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: columns + 1), count: rows + 1)
        for column in 0...columns { table[0][column] = column }
        for row in 0...rows { table[row][0] = row }
        if rows > 0 && columns > 0 {
            for row in 1...rows {
                for column in 1...columns {
                    let same = expected[row - 1] == heard[column - 1]
                    table[row][column] = min(
                        table[row - 1][column] + 1,
                        table[row][column - 1] + 1,
                        table[row - 1][column - 1] + (same ? 0 : 1)
                    )
                }
            }
        }

        // Trace a cheapest path back from the bottom-right corner. The order of the checks
        // decides which of several equally cheap paths is shown: a match first, then a
        // replaced word, then an extra word, then a missing one.
        var tokens: [Token] = []
        var row = rows
        var column = columns
        while row > 0 || column > 0 {
            let cell = table[row][column]
            if row > 0, column > 0, expected[row - 1] == heard[column - 1], cell == table[row - 1][column - 1] {
                tokens.append(Token(word: heard[column - 1], kind: .match))
                row -= 1
                column -= 1
            } else if row > 0, column > 0, cell == table[row - 1][column - 1] + 1 {
                tokens.append(Token(word: heard[column - 1], kind: .substitution(expected: expected[row - 1])))
                row -= 1
                column -= 1
            } else if column > 0, cell == table[row][column - 1] + 1 {
                tokens.append(Token(word: heard[column - 1], kind: .insertion))
                column -= 1
            } else if row > 0 {
                tokens.append(Token(word: expected[row - 1], kind: .deletion))
                row -= 1
            } else {
                break
            }
        }
        return tokens.reversed()
    }
}
