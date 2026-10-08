import Foundation
import Testing

@testable import FluenceCore

struct TranscriptHealthTests {
    @Test func theReportedLoopIsCaught() {
        let looped = Array(repeating: "Node.js", count: 30).joined(separator: ", ")
            + ". Et la cloud, la cloud, ça fait chaud de faire."
        #expect(TranscriptHealth.isDegenerate(looped))
    }

    @Test func repeatedGroupsAreCaught() {
        #expect(TranscriptHealth.isDegenerate("on y va, on y va, on y va, on y va, on y va"))
        #expect(TranscriptHealth.isDegenerate("Merci. Merci. Merci. Merci. Merci. Merci."))
    }

    @Test func aDominantWordIsCaught() {
        let text = "github alors github et github puis github encore github voilà github donc github fin"
        #expect(TranscriptHealth.isDegenerate(text))
    }

    @Test func normalSpeechPasses() {
        let samples = [
            "Quand les transcriptions de réunions sont trop longues, la prise de notes ne marche pas.",
            "C'est très très important, il faut le corriger avant vendredi.",
            "Non non non, ce n'est pas ce que je voulais dire.",
            "Bonjour, je regarde ça et je reviens vers toi demain matin.",
            "On déploie avec Node.js, puis on teste sur Node.js 22 et on compare.",
            "Oui.",
        ]
        for text in samples {
            #expect(!TranscriptHealth.isDegenerate(text), "\(text)")
        }
    }

    @Test func promptIsAShortSentence() {
        let terms = (1...35).map { "Term\($0)" }
        let prompt = WhisperPrompt.build(previous: nil, terms: terms, french: true)
        #expect(prompt == "Vocabulaire : Term1, Term2, Term3, Term4, Term5, Term6, Term7 et Term8.")
    }

    @Test func promptKeepsTheRecentContext() {
        let prompt = WhisperPrompt.build(previous: "Premier point. On parle du budget", terms: ["Vercel"], french: true)
        #expect(prompt == "On parle du budget. Vocabulaire : Vercel.")
    }

    @Test func aLoopedDictationIsNotFedBack() {
        let looped = Array(repeating: "Node.js", count: 30).joined(separator: ", ")
        #expect(WhisperPrompt.build(previous: looped, terms: [], french: true) == nil)
    }

    @Test func promptDeduplicatesAndStaysShort() {
        let prompt = WhisperPrompt.build(
            previous: String(repeating: "mot ", count: 200),
            terms: ["GitHub", "github", "Vercel"],
            french: false
        )
        #expect(prompt?.hasSuffix("Vocabulary: GitHub and Vercel.") == true)
        #expect((prompt?.count ?? 0) <= WhisperPrompt.maximumCharacters)
    }

    @Test func dotsInsideWordsDoNotStartSentences() {
        #expect(RuleCleanup.capitalizeSentences("on utilise node.js et vercel.app. ensuite on teste") == "On utilise node.js et vercel.app. Ensuite on teste")
        #expect(RuleCleanup.capitalizeSentences("version 2.5 prête. «oui.» puis") == "Version 2.5 prête. «Oui.» Puis")
    }
}
