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
        // FLU-122: French words around the franglais triggers.
        "Il nage le crawl tous les matins.",
        "Le dossier est incliné vers la gauche.",
        "Elle a décliné l'offre et souligné le risque.",
        "Le praliné est aligné sur la vitrine.",
        "Une couronne et une crosse sur le trône.",
        "La fête est réussie, le rôle est clair.",
        "Il a chipé un gâteau et poché les œufs.",
    ])
    func frenchStaysAsSaid(_ sentence: String) {
        #expect(lexicon.apply(to: sentence).text == sentence)
    }

    @Test func theLexiconStillCorrectsWhatItIsFor() {
        #expect(lexicon.apply(to: "on fait un colle demain").text == "on fait un call demain")
        #expect(lexicon.apply(to: "ouvre une poule request").text == "ouvre une pull request")
    }

    /// English work words said the French way and written as French look-alikes that are not
    /// French words (FLU-122: Clement's « crone », « cline », « liné »; the bench's franglais set).
    @Test(arguments: [
        ("Le crône tourne toutes les nuits.", "Le cron tourne toutes les nuits."),
        ("mets le script en crone", "mets le script en cron"),
        ("il faut cline le code", "il faut clean le code"),
        ("J'ai cléané la branche, il faut cliner le reste.", "J'ai cleané la branche, il faut cleaner le reste."),
        ("on a cliné les tests", "on a cleané les tests"),
        ("On a liné le process et léané l'équipe.", "On a leané le process et leané l'équipe."),
        ("La féature est prête, les féatures aussi.", "La feature est prête, les features aussi."),
        ("un gros réfacto, un gros réfecto", "un gros refacto, un gros refacto"),
        ("le backlow du sprint et la roadma", "le backlog du sprint et la roadmap"),
        ("j'ai pûché le fix et chippé la feature", "j'ai pushé le fix et shippé la feature"),
    ])
    func franglaisLookAlikesBecomeTheEnglishWord(_ heard: String, _ meant: String) {
        #expect(lexicon.apply(to: heard).text == meant)
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
