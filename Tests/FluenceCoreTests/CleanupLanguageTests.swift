import Foundation
import Testing

@testable import FluenceCore

private let nbsp = "\u{00A0}"

struct CleanupLevelTests {
    @Test func oldSwitchesMapToTheBehaviourTheyHad() {
        #expect(CleanupLevel.migrated(cleanupEnabled: nil, smartCleanup: nil) == .light)
        #expect(CleanupLevel.migrated(cleanupEnabled: true, smartCleanup: false) == .light)
        #expect(CleanupLevel.migrated(cleanupEnabled: true, smartCleanup: true) == .medium)
        #expect(CleanupLevel.migrated(cleanupEnabled: false, smartCleanup: true) == .none)
        #expect(CleanupLevel.migrated(cleanupEnabled: false, smartCleanup: nil) == .none)
    }

    @Test func onlyHighRestyles() {
        #expect(CleanupLevel.allCases.filter(\.usesModel) == [.medium, .high])
        #expect(CleanupLevel.allCases.filter(\.appliesStyle) == [.high])
    }
}

struct LanguageTests {
    @Test func aChosenLanguageIsTakenAtItsWord() {
        #expect(DictationLanguage.detect("the meeting is tomorrow", selected: .french, fallback: .english) == .french)
    }

    @Test func frenchAndEnglishAreToldApartOnOneSentence() {
        #expect(DictationLanguage.detect("je pense que c'est bien pour demain", selected: .auto, fallback: .english) == .french)
        #expect(DictationLanguage.detect("I think that it is fine for tomorrow", selected: .auto, fallback: .french) == .english)
    }

    @Test func otherLanguagesGoToTheRecognizer() {
        let german = "Ich glaube, dass wir das Treffen morgen früh im Büro machen sollten, weil alle dort sind."
        #expect(DictationLanguage.detect(german, selected: .auto, fallback: .english) == .german)
    }

    @Test func tooLittleToGoOnFallsBack() {
        #expect(DictationLanguage.detect("OK", selected: .auto, fallback: .french) == .french)
        #expect(DictationLanguage.detect("OK", selected: .auto, fallback: .auto) == .english)
    }

    @Test func appleLocalePrefersTheUsersRegion() {
        let belgian = Locale(identifier: "fr_BE")
        #expect(DictationLanguage.french.appleLocaleIdentifier(current: belgian) == "fr_BE")
        #expect(DictationLanguage.english.appleLocaleIdentifier(current: belgian) == "en-US")
        #expect(DictationLanguage.auto.appleLocaleIdentifier(current: belgian) == "fr_BE")
        #expect(DictationLanguage(locale: belgian) == .french)
    }

    @Test func everyParakeetLanguageIsListed() {
        #expect(DictationLanguage.spoken.count == 25)
    }
}

struct EnglishRuleTests {
    private func clean(_ text: String) -> String { RuleCleanup.apply(text, language: .english) }

    @Test func fillersSpacingCapitalsAndFullStop() {
        #expect(clean("um so I think, uh, we should go") == "So I think, we should go.")
    }

    @Test func spokenLineBreaksLeaveNoStraySpaces() {
        #expect(clean("first point new line second point") == "First point\nSecond point.")
        #expect(clean("hello new paragraph next topic") == "Hello\n\nNext topic.")
    }

    @Test func parenthesesHugTheirContents() {
        #expect(clean("the budget open paren draft close paren is ready") == "The budget (draft) is ready.")
    }

    @Test func frenchFillersAreNotEnglishOnes() {
        // "ben" in English text is a name and stays.
        #expect(clean("ask ben about it") == "Ask ben about it.")
    }
}

struct FrenchRuleTests {
    private func clean(_ text: String) -> String { RuleCleanup.apply(text, language: .french) }

    @Test func hesitationsGo() {
        #expect(clean("euh je pense que, euh, c'est bon") == "Je pense que, c'est bon.")
        #expect(clean("bah oui on peut") == "Oui on peut.")
        #expect(clean("ben, je sais pas") == "Je sais pas.")
    }

    @Test func benTheNameStays() {
        #expect(clean("Ben, tu viens demain") == "Ben, tu viens demain.")
        #expect(clean("j'ai vu Ben hier") == "J'ai vu Ben hier.")
    }

    @Test func genreOnlyWhenItIsAFiller() {
        #expect(clean("c'est, genre, super loin") == "C'est, super loin.")
        #expect(clean("c'est un genre de musique") == "C'est un genre de musique.")
    }

    @Test func duCoupOnlyWhenItIsAFiller() {
        #expect(clean("on part, du coup, à huit heures") == "On part, à huit heures.")
        #expect(clean("on y va du coup") == "On y va.")
        #expect(clean("du coup on y va") == "Du coup on y va.")
    }

    @Test func voilaIsLeftAlone() {
        #expect(clean("voilà le dossier") == "Voilà le dossier.")
    }

    @Test func spokenPunctuation() {
        #expect(clean("tu viens demain point d'interrogation") == "Tu viens demain\(nbsp)?")
        #expect(clean("bonjour virgule ça va") == "Bonjour, ça va.")
        #expect(clean("trois choses deux points le pain virgule le lait") == "Trois choses\(nbsp): le pain, le lait.")
        #expect(clean("c'est fini point") == "C'est fini.")
        #expect(clean("première ligne à la ligne deuxième ligne") == "Première ligne\nDeuxième ligne.")
        #expect(clean("intro nouveau paragraphe suite") == "Intro\n\nSuite.")
        #expect(clean("le budget ouvrez la parenthèse provisoire fermez la parenthèse est prêt")
            == "Le budget (provisoire) est prêt.")
        #expect(clean("il a dit ouvrez les guillemets oui fermez les guillemets")
            == "Il a dit «\(nbsp)oui\(nbsp)».")
    }

    @Test func wordsThatOnlySoundLikeCommands() {
        // A noun, a score, a decimal comma, a line in a document.
        #expect(clean("c'est le point important") == "C'est le point important.")
        #expect(clean("à ce point") == "À ce point.")
        #expect(clean("on a marqué deux points") == "On a marqué deux points.")
        #expect(clean("il mesure 3 virgule 5 mètres") == "Il mesure 3,5 mètres.")
        #expect(clean("regarde la virgule") == "Regarde la virgule.")
        #expect(clean("l'erreur est à la ligne 12") == "L'erreur est à la ligne 12.")
    }
}

struct FrenchTypographyTests {
    @Test func spacesBeforeHighPunctuation() {
        #expect(FrenchTypography.apply(to: "Bonjour ! Ça va? Oui : très bien; merci.")
            == "Bonjour\(nbsp)! Ça va\(nbsp)? Oui\(nbsp): très bien\(nbsp); merci.")
    }

    @Test func guillemets() {
        #expect(FrenchTypography.apply(to: "Il a dit «oui» puis « non »") == "Il a dit «\(nbsp)oui\(nbsp)» puis «\(nbsp)non\(nbsp)»")
    }

    @Test func isIdempotent() {
        let once = FrenchTypography.apply(to: "Quoi ?! « Vraiment » : oui !")
        #expect(FrenchTypography.apply(to: once) == once)
        #expect(once == "Quoi\(nbsp)?! «\(nbsp)Vraiment\(nbsp)»\(nbsp): oui\(nbsp)!")
    }

    @Test func leavesTimesAddressesAndSmileysAlone() {
        #expect(FrenchTypography.apply(to: "Rendez-vous à 14:30") == "Rendez-vous à 14:30")
        #expect(FrenchTypography.apply(to: "Voir https://exemple.fr/page?id=2") == "Voir https://exemple.fr/page?id=2")
        #expect(FrenchTypography.apply(to: "Écris à jean@exemple.fr") == "Écris à jean@exemple.fr")
        #expect(FrenchTypography.apply(to: "Super :)") == "Super :)")
    }
}

struct FrenchGuardTests {
    private func verdict(_ original: String, _ cleaned: String, restyled: Bool = false) -> CleanupGuard.Verdict {
        CleanupGuard.evaluate(original: original, cleaned: cleaned, language: .french, restyled: restyled)
    }

    @Test func frenchCleanupWithNumbersAndASelfCorrectionIsAccepted() {
        #expect(verdict("euh on se voit à dix sept heures non en fait dix huit heures", "On se voit à 18 heures.") == .accepted)
        #expect(verdict("il y a quatre vingt dix neuf personnes", "Il y a 99 personnes.") == .accepted)
        #expect(verdict("deux mille vingt six", "2026") == .accepted)
        #expect(verdict("soixante et onze euros", "71 euros") == .accepted)
    }

    @Test func frenchElisionsAreNotInventions() {
        #expect(verdict("j ai vu le document c est bon", "J'ai vu le document, c'est bon.") == .accepted)
    }

    @Test func anAnsweredFrenchQuestionIsRejected() {
        guard case .inventedWords = verdict("quelle est la capitale de la france", "La capitale de la France est Paris.") else {
            Issue.record("an answer must be rejected in French too")
            return
        }
    }

    @Test func frenchCommentaryIsRejected() {
        #expect(verdict("envoie le rapport", "Voici le texte : envoie le rapport.") != .accepted)
    }

    @Test func restylingMaySwapGrammarWordsButNotAddContent() {
        // "vous" for "tu" is register; "pouvez" for "peux" is a new word form, and the guard
        // stays strict about content words even when restyling.
        #expect(verdict("tu peux m envoyer le rapport", "Pouvez-vous m'envoyer le rapport ?", restyled: true) == .inventedWords(1))
        #expect(verdict("tu as le rapport", "Vous avez le rapport ?", restyled: true) == .accepted)
        #expect(CleanupGuard.evaluate(
            original: "I don't think we can make it", cleaned: "I do not think we can make it.",
            language: .english, restyled: true
        ) == .accepted)
        guard case .inventedWords = CleanupGuard.evaluate(
            original: "what is the capital of france", cleaned: "The capital of France is Paris.",
            language: .english, restyled: true
        ) else {
            Issue.record("restyling must not let an answer through")
            return
        }
    }

    @Test func englishBehaviourIsUnchangedByDefault() {
        #expect(CleanupGuard.evaluate(original: "send it to le bureau", cleaned: "Send it to le bureau.") == .accepted)
    }
}

struct CleanupPromptTests {
    @Test func frenchGetsFrenchInstructions() {
        let text = CleanupPrompt.instructions(language: .french, style: nil, hasPlaceholders: false)
        #expect(text.contains("Tu nettoies"))
        #expect(!text.contains("Style"))
        #expect(CleanupPrompt.prompt(for: "x", language: .french).hasPrefix("Nettoie"))
    }

    @Test func otherLanguagesAreToldToStayInTheirLanguage() {
        let text = CleanupPrompt.instructions(language: .german, style: nil, hasPlaceholders: false)
        #expect(text.contains("You clean up"))
        #expect(text.contains("The transcript is in German"))
        #expect(!CleanupPrompt.instructions(language: .english, style: nil, hasPlaceholders: false).contains("The transcript is in"))
    }

    @Test func styleAndPlaceholdersOnlyWhenAsked() {
        let styled = CleanupPrompt.instructions(
            language: .english, style: .init(style: .veryCasual, category: .personal), hasPlaceholders: true
        )
        #expect(styled.contains("very casual"))
        #expect(styled.contains("personal message"))
        #expect(styled.contains("⟦1⟧"))
        let french = CleanupPrompt.instructions(
            language: .french, style: .init(style: .formal, category: .email), hasPlaceholders: false
        )
        #expect(french.contains("un e-mail"))
        #expect(french.contains("tutoiement"))
    }
}
