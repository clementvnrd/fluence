import Testing

@testable import FluenceMeetingCore

/// FLU-147: Parakeet answers « Yeah », « Okay », « Mm-hmm » to a sip, a cough or a click the
/// VAD let through. The values below are the measured ones (docs/SPEECH-MODELS.md, meetings).
struct HallucinationGuardTests {
    @Test("a short segment the VAD barely heard is dropped")
    func dropsWeakShortSegments() {
        // A sip of water: « Yeah. », VAD mean 0.37, peak 0.62.
        #expect(!HallucinationGuard.keeps(text: "Yeah.", vad: [0.62, 0.3, 0.2]))
        // A sneeze: mean above the bar, peak under it.
        #expect(!HallucinationGuard.keeps(text: "Okay.", vad: [0.5, 0.86, 0.52]))
        // Two words count as short.
        #expect(!HallucinationGuard.keeps(text: "Mm-hmm.", vad: [0.55, 0.4, 0.3]))
    }

    @Test("real short French answers pass", arguments: ["Oui.", "D'accord.", "Ouais ouais.", "OK."])
    func keepsShortAnswers(_ text: String) {
        // The weakest correctly transcribed answer measured: mean 0.54, peak 0.97.
        #expect(HallucinationGuard.keeps(text: text, vad: [0.97, 0.6, 0.05]))
    }

    @Test("three words or more are kept whatever the VAD says")
    func keepsLongerSegments() {
        #expect(HallucinationGuard.keeps(text: "Je ne sais pas.", vad: [0.2, 0.1]))
    }

    @Test("without VAD evidence (energy fallback, a later launch) nothing is dropped")
    func keepsWithoutEvidence() {
        #expect(HallucinationGuard.keeps(text: "Yeah.", vad: []))
    }

    @Test("an utterance covers every hop it overlaps")
    func hopsOfAnUtterance() {
        let probabilities: [Float] = [0.1, 0.2, 0.9, 1, 0.3, 0.1]
        // Samples 7 000–13 000 with 4 096-sample hops: hops 1, 2 and 3.
        #expect(Array(HallucinationGuard.hops(probabilities, from: 7_000, to: 13_000, hop: 4_096)) == [0.2, 0.9, 1])
        // Inside one hop.
        #expect(Array(HallucinationGuard.hops(probabilities, from: 8_200, to: 8_300, hop: 4_096)) == [0.9])
        // Past what was analysed: clamped, never a crash.
        #expect(Array(HallucinationGuard.hops(probabilities, from: 30_000, to: 40_000, hop: 4_096)) == [0.1])
        #expect(HallucinationGuard.hops([], from: 0, to: 4_096, hop: 4_096).isEmpty)
    }
}

/// FLU-147: on the call channel Parakeet writes short French it half-heard in another language.
/// Clement speaks franglais, so English stays. Sentences from the real meeting, the harness's
/// Parakeet outputs and its short French answers (docs/SPEECH-MODELS.md, meetings).
struct ForeignSegmentTests {
    @Test("a short segment in another language is dropped", arguments: [
        "Här.", "Waar het moet?", "Jetzt hören.", "Das ist Michael.", "Isso é chefe.", "Да, не скрываю.", "Nee, nee.",
    ])
    func dropsForeign(_ text: String) {
        #expect(HallucinationGuard.isForeign(text))
    }

    @Test("short French, English, jargon and numbers stay", arguments: [
        "Oui.", "Non.", "Bah non.", "D'accord.", "Ouais ouais.", "OK.", "Voilà.", "Bah ouais.", "C'est possible.",
        "Euh", "Coucou.", "Vas-y.", "Hier.", "547", "15 %", "GitHub", "Marex", "cash flow", "spec out", "merge",
        "same problem", "Summarize where we stand", "Love you is G.", "Well it's neuf", "Yeah.", "?",
    ])
    func keepsFrenchAndEnglish(_ text: String) {
        #expect(!HallucinationGuard.isForeign(text))
    }

    @Test("four words or more are kept, whatever the language")
    func keepsLongerSegments() {
        #expect(!HallucinationGuard.isForeign("Das ist ein Test."))
    }
}

struct UnknownTokenTests {
    @Test("Parakeet's <unk> never becomes a word")
    func unknownTokensAreSkipped() {
        let tokens = [
            TimedToken(text: " que", start: 0.0, end: 0.2, confidence: 0.9),
            TimedToken(text: " ", start: 0.2, end: 0.3, confidence: 0.9),
            TimedToken(text: "<unk>", start: 0.3, end: 0.4, confidence: 0.99),
            TimedToken(text: " person", start: 0.4, end: 0.6, confidence: 0.9),
            TimedToken(text: "ne", start: 0.6, end: 0.7, confidence: 0.9),
        ]
        #expect(WordBuilder.words(from: tokens, offset: 0).map(\.text) == ["que", "personne"])
    }
}
