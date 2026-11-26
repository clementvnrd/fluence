import FluenceCore
import Foundation
import Testing

/// FLU-149: Cohere Transcribe's guards, from what the bench measured on it (docs/SPEECH-MODELS.md):
/// decoder loops through a webcam mic, and subtitle credits on noise.
struct CohereGuardTests {
    // MARK: (a) the decoder's budget follows the audio

    @Test func theTokenBudgetGrowsWithTheAudio() {
        #expect(CohereGuard.maxTokens(audioSeconds: 0) == 16)
        #expect(CohereGuard.maxTokens(audioSeconds: 2) == 32)
        #expect(CohereGuard.maxTokens(audioSeconds: 10) == 96)
        #expect(CohereGuard.maxTokens(audioSeconds: 2.01) == 33)
    }

    @Test func theTokenBudgetLeavesRoomForTheFastestMeasuredSpeech() {
        // 8.2 tokens/s was the fastest real clip of the bench (FLEURS, franglais, tech).
        for seconds in [1.0, 3.0, 7.5, 20.0, 30.0] {
            #expect(Double(CohereGuard.maxTokens(audioSeconds: seconds)) >= 8.2 * seconds)
        }
    }

    @Test func aBrokenDurationGetsTheSmallestBudget() {
        #expect(CohereGuard.maxTokens(audioSeconds: -.infinity) == 16)
        #expect(CohereGuard.maxTokens(audioSeconds: .nan) == 16)
        #expect(CohereGuard.maxTokens(audioSeconds: -3) == 16)
    }

    // MARK: (b) a phrase looping back to back is said once

    @Test func aLoopedPhraseIsKeptOnce() {
        let phrase = "Je vais tester la nouvelle version."
        let looped = Array(repeating: phrase, count: 10).joined(separator: " ")
        #expect(CohereGuard.collapseLoops(looped) == phrase)
    }

    @Test func aLoopCutOffByTheBudgetLosesItsPartialCopy() {
        let looped = "On commence. Oh, oh, oh, oh, oh, oh, oh, oh, oh, oh, oh, oh, oh, oh, oh, oh, oh,"
        #expect(CohereGuard.collapseLoops(looped) == "On commence. Oh,")
        #expect(CohereGuard.collapseLoops("x a b c a b c a b c a b c a b") == "x a b c")
    }

    @Test func whatFollowsALoopStays() {
        #expect(CohereGuard.collapseLoops("le build le build le build le build passe enfin") == "le build passe enfin")
    }

    @Test func ordinaryRepetitionStays() {
        for text in [
            "très très bien",
            "non non non",
            "on y va, on y va, on y va",
            "oui oui oui oui",
            "Il faut, il faut vraiment le faire.",
            "Le test du test du parser passe.",
            "",
        ] {
            #expect(CohereGuard.collapseLoops(text) == text, "\(text)")
        }
    }

    @Test func aCollapsedLoopIsNoLongerDegenerate() {
        let looped = Array(repeating: "ça marche pas", count: 8).joined(separator: " ")
        #expect(TranscriptHealth.isDegenerate(looped))
        #expect(!TranscriptHealth.isDegenerate(CohereGuard.collapseLoops(looped)))
    }

    // MARK: (c) near-silence never reaches the model

    @Test func silenceAndATapAreNotSent() {
        #expect(!CohereGuard.hasSpeech(samples: [Float](repeating: 0, count: 16_000), sampleRate: 16_000))
        #expect(!CohereGuard.hasSpeech(samples: [Float](repeating: 0.0005, count: 32_000), sampleRate: 16_000))
        let tap = (0..<3_200).map { Float(sin(Double($0) * 0.2) * 0.3) }
        #expect(!CohereGuard.hasSpeech(samples: tap, sampleRate: 16_000))
    }

    @Test func aSpokenSecondIsSent() {
        let voiced = (0..<16_000).map { Float(sin(Double($0) * 0.05) * 0.05) }
        #expect(CohereGuard.hasSpeech(samples: voiced, sampleRate: 16_000))
    }

    // MARK: (d) subtitle credits heard in noise

    @Test func subtitleCreditsAloneAreDropped() {
        for text in [
            "Sous-titrage Société Radio-Canada",
            "sous-titrage société radio-canada.",
            "Sous-titres réalisés par la communauté d'Amara.org",
            "Merci d'avoir regardé.",
            "Merci d’avoir regardé cette vidéo !",
        ] {
            #expect(CohereGuard.clean(text) == "", "\(text)")
        }
    }

    @Test func aRealSentenceMentioningThemStays() {
        for text in [
            "Le sous-titrage Société Radio-Canada est en retard.",
            "Merci d'avoir regardé mon dossier hier.",
            "Merci.",
            "Voilà.",
        ] {
            #expect(CohereGuard.clean(text) == text, "\(text)")
        }
    }

    @Test func cleanCollapsesLoopsToo() {
        let looped = Array(repeating: "Ça marche pas.", count: 6).joined(separator: " ")
        #expect(CohereGuard.clean(looped) == "Ça marche pas.")
    }

    // MARK: language and model files

    @Test func theDictationLanguageMapsToCohereCodes() {
        #expect(CohereModel.languageCode(for: .french) == "fr")
        #expect(CohereModel.languageCode(for: .english) == "en")
        #expect(CohereModel.languageCode(for: .german) == "de")
        #expect(CohereModel.languageCode(for: .greek) == "el")
        // Cohere needs its language said; Auto and the languages it lacks get none.
        #expect(CohereModel.languageCode(for: .auto) == nil)
        #expect(CohereModel.languageCode(for: .swedish) == nil)
        #expect(CohereModel.languageCode(for: .russian) == nil)
    }

    @Test func theModelIsPinnedToOneRevision() {
        #expect(CohereModel.revision.count == 40)
        #expect(CohereModel.files.allSatisfy { $0.sha256.count == 64 && $0.bytes > 0 })
        #expect(Set(CohereModel.files.map(\.name)) == ["config.json", "tokenizer.model", "tokenizer_config.json", "model.safetensors"])
        let url = CohereModel.url(for: CohereModel.files[0])
        #expect(url.absoluteString.hasPrefix("https://huggingface.co/lyzgeorge/cohere-transcribe-03-2026-mlx-4bit/resolve/\(CohereModel.revision)/"))
        #expect(CohereModel.totalBytes > 1_500_000_000 && CohereModel.totalBytes < 1_520_000_000)
    }

    @Test func aModelFolderIsCompleteOnlyWithEveryFileAtItsSize() {
        let sizes = Dictionary(uniqueKeysWithValues: CohereModel.files.map { ($0.name, $0.bytes) })
        #expect(CohereModel.isComplete(sizes: sizes))
        var short = sizes
        short["model.safetensors"]! -= 1
        #expect(!CohereModel.isComplete(sizes: short))
        var missing = sizes
        missing["tokenizer.model"] = nil
        #expect(!CohereModel.isComplete(sizes: missing))
        #expect(!CohereModel.isComplete(sizes: [:]))
    }
}
