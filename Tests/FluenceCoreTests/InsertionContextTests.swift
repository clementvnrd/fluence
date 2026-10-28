import Testing

@testable import FluenceCore

/// FLU-93: a dictation fitted to the text around the caret.
struct InsertionContextTests {
    private let nbsp = "\u{00A0}"

    private func fit(
        _ text: String,
        before: String?,
        after: String? = nil,
        chat: Bool = false,
        spacingOnly: Bool = false,
        names: Set<String> = []
    ) -> String {
        InsertionContext.adjust(text, before: before, after: after, chat: chat, spacingOnly: spacingOnly, names: names)
    }

    // MARK: The issue's two examples

    @Test func secondDictationInTheSameFieldGetsASpace() {
        #expect(fit("Comment ça va\(nbsp)?", before: "Bonjour.", after: "") == " Comment ça va\(nbsp)?")
    }

    @Test func middleOfASentenceIsLowerCasedWithoutAStop() {
        // Caret after « que », before « est validé »: one dictation fills the gap.
        #expect(fit("Le budget.", before: "je pense que ", after: "est validé.") == "le budget ")
        #expect(fit("Le budget.", before: "je pense que", after: " est validé.") == " le budget")
        // Caret at the end of the unfinished sentence: the stop stays, nothing follows.
        #expect(fit("Le budget est validé.", before: "je pense que", after: "") == " le budget est validé.")
    }

    @Test func lightOutputIsFittedRatherThanCleanedTwice() {
        let comment = DoNoHarmTests.light("comment ça va", .french)
        let budget = DoNoHarmTests.light("le budget est validé", .french)
        #expect(fit(comment, before: "Bonjour.", after: "") == " Comment ça va.")
        #expect(fit(budget, before: "je pense que ", after: "") == "le budget est validé.")
        #expect(fit(budget, before: "", after: "", chat: true) == "Le budget est validé")
    }

    // MARK: Where nothing changes

    @Test func emptyFieldOrLineStartKeepsTheText() {
        #expect(fit("Bonjour.", before: "", after: "") == "Bonjour.")
        #expect(fit("Bonjour.", before: "Salut\n", after: "") == "Bonjour.")
        #expect(fit("Bonjour.", before: "Bonjour. ", after: "") == "Bonjour.")
        #expect(fit("Merci.", before: "Bonjour,\r\n", after: "") == "Merci.")
    }

    @Test func unknownContextTypesAsBefore() {
        #expect(fit("Le budget est validé.", before: nil) == "Le budget est validé.")
        #expect(fit("Le budget est validé.", before: nil, after: nil) == "Le budget est validé.")
    }

    @Test func noSpaceAfterAnOpeningOrJoiningCharacter() {
        #expect(fit("Voir plus bas)", before: "(", after: "") == "voir plus bas)")
        #expect(fit("Avion.", before: "l'", after: "") == "avion.")
        #expect(fit("Avion.", before: "l’", after: "") == "avion.")
        #expect(fit("Dessus.", before: "peut-être là-", after: "") == "dessus.")
        #expect(fit("Docs", before: "https://fluence.app/", after: "") == "docs")
        #expect(fit("Oui", before: "«\(nbsp)", after: "") == "oui")
    }

    // MARK: Spacing

    @Test func afterAColonTheSentenceGoesOn() {
        #expect(fit("On commence lundi.", before: "Voici le plan\(nbsp):", after: "") == " on commence lundi.")
        #expect(fit("On commence lundi.", before: "Voici le plan\(nbsp): ", after: "") == "on commence lundi.")
    }

    @Test func afterAnAddressOrANumber() {
        #expect(fit("Merci.", before: "voir https://fluence.app", after: "") == " merci.")
        #expect(fit("Euros de côté.", before: "J'ai 15", after: "") == " euros de côté.")
        #expect(fit("15 h 30.", before: "Rendez-vous à", after: "") == " 15 h 30.")
        #expect(fit("2026.", before: "En", after: "") == " 2026.")
    }

    @Test func spaceBeforeAnOpeningGuillemetOrBracket() {
        #expect(fit("« Oui ».", before: "Il a dit", after: "") == " « oui ».")
        #expect(fit("(Voir plus bas).", before: "Le budget", after: "") == " (voir plus bas).")
    }

    @Test func textStartingWithPunctuationGetsNoSpace() {
        #expect(fit(", et puis voilà.", before: "Bonjour", after: "") == ", et puis voilà.")
        #expect(fit("\(nbsp)?", before: "Ça va", after: "") == "\(nbsp)?")
    }

    @Test func trailingSpaceOnlyBeforeAWord() {
        #expect(fit("Le budget.", before: "que ", after: ".") == "le budget")
        #expect(fit("Le budget.", before: "que ", after: " est") == "le budget")
        #expect(fit("Le budget.", before: "que ", after: "\nest") == "le budget.")
    }

    // MARK: Capitals

    @Test func sentenceEndsKeepTheCapital() {
        #expect(fit("Oui.", before: "Tu viens\(nbsp)?", after: "") == " Oui.")
        #expect(fit("Oui.", before: "Super\(nbsp)!", after: "") == " Oui.")
        #expect(fit("Oui.", before: "Je ne sais pas…", after: "") == " Oui.")
        #expect(fit("Oui.", before: "Il a dit « non ».", after: "") == " Oui.")
        #expect(fit("Oui.", before: "(c'est fait.)", after: "") == " Oui.")
    }

    @Test func midSentenceLowerCasesOnlyTheFirstWord() {
        #expect(fit("Le budget de Paris.", before: "et", after: "") == " le budget de Paris.")
        #expect(fit("Je pense.", before: "Bonjour,", after: "") == " je pense.")
        #expect(fit("J'arrive.", before: "Attends,", after: "") == " j'arrive.")
        #expect(fit("Écoute.", before: "Bon,", after: "") == " écoute.")
    }

    @Test func acronymsInnerCapitalsNamesAndIKeepTheirCase() {
        #expect(fit("PDF final.", before: "on a validé le", after: "") == " PDF final.")
        #expect(fit("GitHub tous les jours.", before: "j'utilise", after: "") == " GitHub tous les jours.")
        #expect(fit("iPhone.", before: "mon", after: "") == " iPhone.")
        #expect(fit("I think so.", before: "and", after: "") == " I think so.")
        #expect(fit("Clément hier.", before: "j'ai vu", after: "", names: ["Clément"]) == " Clément hier.")
    }

    // MARK: Final stop

    @Test func chatDropsTheFinalStopButKeepsQuestionsAndExclamations() {
        #expect(fit("On se voit demain.", before: "", after: "", chat: true) == "On se voit demain")
        #expect(fit("On se voit demain.", before: nil, chat: true) == "On se voit demain")
        #expect(fit("Tu viens\(nbsp)?", before: "", after: "", chat: true) == "Tu viens\(nbsp)?")
        #expect(fit("Génial\(nbsp)!", before: "", after: "", chat: true) == "Génial\(nbsp)!")
        #expect(fit("Bon. On verra.", before: "", after: "", chat: true) == "Bon. On verra")
        #expect(fit("Je ne sais pas...", before: "", after: "", chat: true) == "Je ne sais pas...")
        #expect(fit("Ok.", before: "Salut.", after: "", chat: true) == " Ok")
    }

    @Test func outsideAChatTheStopStaysWhenNothingFollowsOnTheLine() {
        #expect(fit("On se voit demain.", before: "", after: "") == "On se voit demain.")
        #expect(fit("On se voit demain.", before: "", after: "   \nSuite") == "On se voit demain.")
        #expect(fit("On se voit demain.", before: "", after: " suite") == "On se voit demain")
    }

    // MARK: Developer tools, snippets

    @Test func spacingOnlyNeverChangesCaseOrPunctuation() {
        #expect(fit("Git status.", before: "echo", after: "", spacingOnly: true) == " Git status.")
        #expect(fit("Cordialement, Clément.", before: "Merci,", after: "x", chat: true, spacingOnly: true)
            == " Cordialement, Clément. ")
        #expect(fit("Ls", before: "$ ", after: "", spacingOnly: true) == "Ls")
    }

    @Test func emptyTextStaysEmpty() {
        #expect(fit("", before: "Bonjour", after: "x") == "")
    }

    // MARK: Fallback memory

    @Test func memoryGuessesOnlyForTheSameAppSoonAndUntyped() {
        let memory = InsertionContext.Memory(bundleID: "com.tinyspeck.slackmacgap", text: "Bonjour à tous", at: 1000)
        #expect(memory.tail == "tous")
        #expect(memory.before(bundleID: "com.tinyspeck.slackmacgap", now: 1100, lastKeyAt: 900) == "tous")
        #expect(memory.before(bundleID: "com.apple.notes", now: 1100, lastKeyAt: 900) == nil)
        #expect(memory.before(bundleID: nil, now: 1100, lastKeyAt: 900) == nil)
        #expect(memory.before(bundleID: "com.tinyspeck.slackmacgap", now: 1120, lastKeyAt: 900) == nil)
        // A key typed since (a Return that sent the message): the guess is off.
        #expect(memory.before(bundleID: "com.tinyspeck.slackmacgap", now: 1100, lastKeyAt: 1050) == nil)
    }
}
