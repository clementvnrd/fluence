import Foundation
import Testing

@testable import FluenceCore

/// FLU-88: « Apprendre les termes fréquents » filled the dictionary with « prêt. », « Je »,
/// « peut-être »… and those newest entries pushed real names out of the engines' bias list.
struct FrequentTermsTests {
    @Test func ordinaryFrenchTeachesNothing() {
        #expect(FrequentTerms.candidates(in: "Je pense que c'est peut-être prêt. Je t'appelle demain. Merci, à plus.").isEmpty)
        #expect(FrequentTerms.candidates(in: "Est-ce que tu viens ? Vas-y. On se voit aujourd'hui.").isEmpty)
    }

    @Test func namesAndJargonComeWithoutTheirPunctuation() {
        #expect(FrequentTerms.candidates(in: "J'ai montré à Claude le code SwiftUI, puis l'API de Next.js et la CI/CD.")
            == ["Claude", "SwiftUI", "API", "Next.js", "CI/CD"])
        #expect(FrequentTerms.candidates(in: "On en parle avec Jean-Luc.") == ["Jean-Luc"])
    }

    @Test func aCapitalOnlyCountsMidSentence() {
        #expect(FrequentTerms.candidates(in: "Anthropic. Mistral ! Notion ? Apple") == [])
        #expect(FrequentTerms.candidates(in: "J'ai vu Notion » hier.") == ["Notion"])
    }

    @Test func offeredAfterThreeUsesOnTwoDays() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let monday = Date(timeIntervalSince1970: 1_800_000_000)
        let tuesday = monday.addingTimeInterval(86_400)
        var terms = FrequentTerms()

        // Three uses in one day are not enough; nor is one dictation that says it three times.
        #expect(terms.record("Je parle de Claude, Claude et Claude.", at: monday, calendar: utc).isEmpty)
        #expect(terms.record("Merci à Claude.", at: monday, calendar: utc).isEmpty)
        #expect(terms.record("Je vois Claude.", at: monday, calendar: utc).isEmpty)
        #expect(terms.record("Merci, Claude.", at: tuesday, calendar: utc) == ["Claude"])

        // Two uses over two days are not enough either.
        #expect(terms.record("Avec Mistral.", at: monday, calendar: utc).isEmpty)
        #expect(terms.record("Avec Mistral.", at: tuesday, calendar: utc).isEmpty)
        #expect(terms.record("Avec Mistral.", at: tuesday, calendar: utc) == ["Mistral"])
    }
}
