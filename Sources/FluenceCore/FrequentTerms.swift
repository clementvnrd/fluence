import Foundation

/// « Apprendre les termes fréquents » (FLU-88): the names and jargon in Fluence's own output,
/// counted until they are clearly the user's vocabulary, then *offered* — never added.
///
/// In memory only: a stored tally of the words someone dictates would be a record of what they said.
public struct FrequentTerms {
    /// A term is offered once used this many times, on at least `days` different days.
    public static let uses = 3
    public static let days = 2

    private var seen: [String: (uses: Int, days: Set<Date>)] = [:]

    public init() {}

    /// Counts the terms of `text`, dictated at `date`, and returns those that are now due.
    public mutating func record(_ text: String, at date: Date, calendar: Calendar = .current) -> [String] {
        let day = calendar.startOfDay(for: date)
        var due: [String] = []
        for term in Self.candidates(in: text) {
            var tally = seen[term] ?? (0, [])
            tally.uses += 1
            tally.days.insert(day)
            seen[term] = tally
            if tally.uses >= Self.uses, tally.days.count >= Self.days { due.append(term) }
        }
        return due
    }

    /// The words of `text` that look like a name or a term of art, without the punctuation
    /// around them: an acronym (« API »), inner capitals (« SwiftUI »), an inner dot, slash or
    /// hyphen (« Next.js », « CI/CD », « Jean-Luc »), a capital in mid-sentence (« Claude »).
    /// Never an everyday word, nor a capital that only opens a sentence (« Merci. Je… »).
    public static func candidates(in text: String) -> [String] {
        var terms: [String] = []
        var sentenceStart = true
        for raw in text.split(whereSeparator: \.isWhitespace) {
            let startsSentence = sentenceStart
            // « prêt. », « viens ? », « dit. » » end a sentence; a lone closing quote keeps the state.
            if let last = raw.last(where: { !"»\"”’')]".contains($0) }) { sentenceStart = ".!?…".contains(last) }

            var word = raw.trimmingCharacters(in: .punctuationCharacters)
            // Elisions: « l'API » is API, « d'Apple » is Apple.
            if let elision = word.range(of: "^(?:[cdjlmnst]|qu)['’]", options: [.regularExpression, .caseInsensitive]) {
                word.removeSubrange(elision)
            }
            guard word.count(where: \.isLetter) >= 2, !isOrdinary(word), !terms.contains(word) else { continue }

            let isAcronym = word.count <= 6 && word.allSatisfy { $0.isUppercase || $0.isNumber }
            let innerCapital = word.dropFirst().contains(where: \.isUppercase)
            let innerMark = word.contains { ".-/".contains($0) }
            let midSentenceCapital = !startsSentence && word.first?.isUppercase == true
            if isAcronym || innerCapital || innerMark || midSentenceCapital { terms.append(word) }
        }
        return terms
    }

    /// An everyday word, or a hyphenated one built on an everyday word (« peut-être », « Est-ce »).
    static func isOrdinary(_ word: String) -> Bool {
        word.split(separator: "-").contains { EditLearner.isCommon(String($0)) }
    }

    /// A dictionary term that was most likely learned by mistake (FLU-88): it ends a sentence
    /// (« demain. »), or it is an everyday word or pronoun (« Merci », « Je », « peut-être »).
    /// Only ever shown to the user, who decides.
    public static func isSuspect(_ term: String) -> Bool {
        guard let last = term.last else { return false }
        return ".,;:!?…".contains(last) || isOrdinary(term)
    }
}
