import Foundation
import Testing

@testable import FluenceDictionary

/// The built-in tech lexicon must not rewrite ordinary French (FLU-30, F8): an entry whose
/// trigger is also a French verb or noun phrase fires on every sentence that says it.
struct TechLexiconTests {
    private let lexicon = DictionaryCorrector(entries: TechLexicon.defaultEntries)

    @Test(arguments: [
        "Je le colle dans Slack.",
        "J'en colle une copie dans le ticket.",
        "On travaille sur la branche master.",
        "La branche master est protégée.",
    ])
    func frenchStaysAsSaid(_ sentence: String) {
        #expect(lexicon.apply(to: sentence).text == sentence)
    }

    @Test func theLexiconStillCorrectsWhatItIsFor() {
        #expect(lexicon.apply(to: "on fait un colle demain").text == "on fait un call demain")
        #expect(lexicon.apply(to: "ouvre une poule request").text == "ouvre une pull request")
    }

    /// Entries dropped from the lexicon stay in a dictionary they were seeded into; the user
    /// removes them in one click, and only those still exactly as seeded.
    @Test func retiredEntriesAreFoundOnlyWhenUntouched() {
        let seeded = DictionaryEntry.correction(hear: "le colle", write: "le call")
        let edited = DictionaryEntry.correction(hear: "branche master", write: "branche master")
        let alsoSeeded = DictionaryEntry.correction(hear: "en colle", write: "en call")
        var disabled = DictionaryEntry.correction(hear: "branche master", write: "branch master")
        disabled.isEnabled = false
        let entries = [seeded, edited, alsoSeeded, disabled, .term("Fluence")]

        let found = TechLexicon.retiredEntries(in: entries)
        // An edited or disabled entry is the user's own now: it stays.
        #expect(found.map(\.id) == [seeded.id, alsoSeeded.id])
        #expect(TechLexicon.defaultEntries.allSatisfy { TechLexicon.retiredEntries(in: [$0]).isEmpty })
    }
}
