import Foundation
import Testing

@testable import FluenceCore

/// FLU-31: the models on disk, which ones are still used, what they weigh.
struct SpeechModelInventoryTests {
    private let nbsp = FrenchFormat.space

    private let parakeetUser = SpeechModelSettings(engine: .parakeet, whisperVariant: "openai_whisper-small", vocabularyBoost: false)

    /// Clement's Air on 2026-10-26, sizes as measured on disk.
    private let clementsDisk: [SpeechModel: Int64] = [
        .parakeetUltra: 632_300_000,
        .parakeetV3: 483_300_000,
        .whisperSmall: 486_500_000,
        .whisperTurbo: 3_195_100_000,
    ]

    @Test func sizesReadTheFrenchWay() {
        #expect(FrenchFormat.bytes(3_195_100_000) == "3,2\(nbsp)Go")
        #expect(FrenchFormat.bytes(632_300_000) == "632\(nbsp)Mo")
        #expect(FrenchFormat.bytes(19_600_000) == "20\(nbsp)Mo")
        #expect(FrenchFormat.bytes(999_700_000) == "1,0\(nbsp)Go")
        #expect(FrenchFormat.bytes(4_500) == "5\(nbsp)Ko")
        #expect(FrenchFormat.bytes(12) == "12\(nbsp)o")
        #expect(FrenchFormat.bytes(-5) == "0\(nbsp)o")
    }

    /// The picker announced "~1,5 Go" for a model that takes 3,2 Go.
    @Test func turboLabelSaysWhatItWeighs() {
        #expect(SpeechModel.whisperTurbo.pickerTitle == "Whisper Large Turbo (~3,2\(nbsp)Go)")
        #expect(SpeechModel.whisperSmall.pickerTitle == "Whisper Small (~487\(nbsp)Mo)")
    }

    @Test func whisperVariantsRoundTrip() {
        for model in SpeechModel.allCases {
            guard let variant = model.whisperVariant else { continue }
            #expect(SpeechModel.whisper(variant: variant) == model)
        }
        #expect(SpeechModel.whisper(variant: "openai_whisper-tiny") == nil)
    }

    @Test func clementsUnusedModelsAreTheThreeHeavyOnes() {
        let models = SpeechModelInventory.installed(sizes: clementsDisk, settings: parakeetUser)
        #expect(models.map(\.model) == [.parakeetUltra, .whisperTurbo, .whisperSmall, .parakeetV3])
        #expect(models.filter(\.canDelete).map(\.model) == [.whisperTurbo, .whisperSmall, .parakeetV3])
        #expect(SpeechModelInventory.reclaimableBytes(models) == 3_195_100_000 + 486_500_000 + 483_300_000)
        #expect(models[0].subtitle == "632\(nbsp)Mo · utilisé")
        #expect(models[1].subtitle == "3,2\(nbsp)Go")
    }

    /// Meetings transcribe with Parakeet Ultra whatever the dictation engine.
    @Test func parakeetUltraIsNeverDeletable() {
        for engine in [SpeechModelSettings.Engine.apple, .whisper, .parakeet] {
            let settings = SpeechModelSettings(engine: engine, whisperVariant: "openai_whisper-small", vocabularyBoost: false)
            #expect(SpeechModel.parakeetUltra.usage(settings) != nil)
        }
    }

    @Test func theSelectedWhisperIsInUseOnlyWithWhisper() {
        let whisper = SpeechModelSettings(engine: .whisper, whisperVariant: "openai_whisper-large-v3_turbo", vocabularyBoost: false)
        #expect(SpeechModel.whisperTurbo.usage(whisper) == .dictation)
        #expect(SpeechModel.whisperSmall.usage(whisper) == nil)
        // Chosen in the picker once, but Parakeet dictates: nothing loads it.
        let parakeet = SpeechModelSettings(engine: .parakeet, whisperVariant: "openai_whisper-large-v3_turbo", vocabularyBoost: false)
        #expect(SpeechModel.whisperTurbo.usage(parakeet) == nil)
    }

    @Test func vocabularyModelFollowsTheToggle() {
        var settings = parakeetUser
        #expect(SpeechModel.parakeetVocabulary.usage(settings) == nil)
        settings.vocabularyBoost = true
        #expect(SpeechModel.parakeetVocabulary.usage(settings) == .vocabulary)
    }

    @Test func parakeetV3IsNeverUsedByTheApp() {
        for engine in [SpeechModelSettings.Engine.apple, .whisper, .parakeet] {
            let settings = SpeechModelSettings(engine: engine, whisperVariant: "openai_whisper-small", vocabularyBoost: true, compareMode: true)
            #expect(SpeechModel.parakeetV3.usage(settings) == nil)
        }
    }

    @Test func absentModelsAreNotListed() {
        let models = SpeechModelInventory.installed(sizes: [.parakeetUltra: 1], settings: parakeetUser)
        #expect(models.map(\.model) == [.parakeetUltra])
        #expect(SpeechModelInventory.installed(sizes: [:], settings: parakeetUser).isEmpty)
    }

    @Test func totalCountsEverything() {
        let models = SpeechModelInventory.installed(sizes: clementsDisk, settings: parakeetUser)
        #expect(SpeechModelInventory.totalBytes(models) == clementsDisk.values.reduce(0, +))
    }
}
