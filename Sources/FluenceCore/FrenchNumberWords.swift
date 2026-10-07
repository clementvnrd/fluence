import Foundation

/// French spoken numbers to digits, for `CleanupGuard` — the counterpart of `NumberWords`.
///
/// Without it a French cleanup that writes "3" for "trois" looks like an invented word and
/// is thrown away. Like `NumberWords` it only has to agree with itself on both sides of the
/// comparison: "un"/"une" become "1" whether they were an article or a number, on both
/// sides alike, so nothing is lost.
///
/// French is additive ("soixante dix" = 60 + 10, "vingt et un" = 20 + 1) except for three
/// multipliers: "quatre vingt" (80), "cent" and the scales. Hyphens have already split
/// "quatre-vingt-dix-sept" into words by the time this runs.
enum FrenchNumberWords {
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
        var index = start

        while index < words.count {
            let word = words[index]

            // "vingt et un", "soixante et onze": the "et" belongs to the number.
            if word == "et", last == .tens, index + 1 < words.count,
               let next = units[words[index + 1]], next == 1 || next == 11 {
                index += 1
                continue
            }

            if let value = units[word] {
                if value < 10 {
                    // After "dix" (10, 70, 90) a unit completes it: "dix sept", "quatre vingt dix neuf".
                    let afterDix = last == .teen && [10, 70, 90].contains(current % 100)
                    guard [.start, .tens, .hundred, .scale].contains(last) || afterDix,
                          value != 0 || last == .start else { break }
                    current += value
                    last = .unit
                    if value == 0 { index += 1; break }
                } else {
                    // 10–16. After 60 or 80 they complete the number: "soixante dix", "quatre vingt seize".
                    let completesTens = last == .tens && (current % 100 == 60 || current % 100 == 80)
                    guard [.start, .hundred, .scale].contains(last) || completesTens else { break }
                    current += value
                    last = .teen
                }
            } else if let value = tens[word] {
                if value == 20, last == .unit, current % 100 == 4 {
                    current += 76 // quatre (4) vingt → 80
                    last = .tens
                } else {
                    guard [.start, .hundred, .scale].contains(last) else { break }
                    current += value
                    last = .tens
                }
            } else if word == "cent" || word == "cents" {
                guard [.start, .unit, .digits].contains(last), current < 10 else { break }
                current = max(current, 1) * 100
                last = .hundred
            } else if let scale = scales[word] {
                guard last != .scale else { break }
                total += max(current, 1) * scale
                current = 0
                last = .scale
            } else if last == .start, let value = Int(word), index + 1 < words.count,
                      words[index + 1].hasPrefix("cent") || scales[words[index + 1]] != nil {
                // "5 millions", "3 cents": digits a scale word goes on to multiply.
                current = value
                last = .digits
            } else {
                break
            }
            index += 1
        }

        guard index > start, last != .digits else { return nil }
        return (String(total + current), index - start)
    }

    private static let units: [String: Int] = [
        "zéro": 0, "un": 1, "une": 1, "deux": 2, "trois": 3, "quatre": 4, "cinq": 5, "six": 6,
        "sept": 7, "huit": 8, "neuf": 9, "dix": 10, "onze": 11, "douze": 12, "treize": 13,
        "quatorze": 14, "quinze": 15, "seize": 16,
    ]

    private static let tens: [String: Int] = [
        "vingt": 20, "vingts": 20, "trente": 30, "quarante": 40, "cinquante": 50, "soixante": 60,
    ]

    private static let scales: [String: Int] = [
        "mille": 1_000, "million": 1_000_000, "millions": 1_000_000,
        "milliard": 1_000_000_000, "milliards": 1_000_000_000,
    ]
}
