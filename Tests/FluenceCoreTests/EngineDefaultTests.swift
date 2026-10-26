import Foundation
import Testing

@testable import FluenceCore

/// FLU-29 / FLU-39: Parakeet Ultra for French and Auto, Apple until it is on disk.
struct EngineDefaultTests {
    @Test func frenchAndAutoPreferParakeet() {
        #expect(EngineDefault.preferred(for: .french) == .parakeet)
        #expect(EngineDefault.preferred(for: .auto) == .parakeet)
        for language in DictationLanguage.allCases where language != .french && language != .auto {
            #expect(EngineDefault.preferred(for: language) == .apple)
        }
    }

    @Test func appleListensUntilParakeetIsReady() {
        #expect(EngineDefault.active(chosen: nil, language: .french, parakeetReady: false) == .apple)
        #expect(EngineDefault.active(chosen: nil, language: .french, parakeetReady: true) == .parakeet)
        #expect(EngineDefault.active(chosen: .parakeet, language: .english, parakeetReady: false) == .apple)
        #expect(EngineDefault.isWaitingForParakeet(chosen: nil, language: .auto, parakeetReady: false))
        #expect(!EngineDefault.isWaitingForParakeet(chosen: nil, language: .auto, parakeetReady: true))
    }

    @Test func anExplicitChoiceWins() {
        #expect(EngineDefault.selected(chosen: .apple, language: .french) == .apple)
        #expect(EngineDefault.active(chosen: .whisper, language: .french, parakeetReady: false) == .whisper)
        #expect(!EngineDefault.isWaitingForParakeet(chosen: .apple, language: .french, parakeetReady: false))
    }

    @Test func theOnboardingStepOnlyForFrenchOrAutoWithoutTheModel() {
        #expect(EngineDefault.offersParakeetStep(language: .french, parakeetReady: false))
        #expect(EngineDefault.offersParakeetStep(language: .auto, parakeetReady: false))
        #expect(!EngineDefault.offersParakeetStep(language: .french, parakeetReady: true))
        #expect(!EngineDefault.offersParakeetStep(language: .english, parakeetReady: false))
    }
}

/// FLU-29: a cancelled download is not a downloaded model.
struct ModelFolderCheckTests {
    private let bundles: Set<String> = ["Encoder.mlmodelc", "Decoder.mlmodelc"]
    private let vocabulary: Set<String> = ["parakeet_vocab.json"]

    private var complete: Set<String> {
        ["Encoder.mlmodelc/coremldata.bin", "Encoder.mlmodelc/model.mil", "Encoder.mlmodelc/weights/weight.bin",
         "Decoder.mlmodelc/coremldata.bin", "Decoder.mlmodelc/weights/weight.bin", "parakeet_vocab.json", "config.json"]
    }

    @Test func aCompleteFolderPasses() {
        #expect(ModelFolderCheck.isComplete(files: complete, bundles: bundles, otherFiles: vocabulary))
    }

    @Test func aBundleWithoutItsWeightsFails() {
        var files = complete
        files.remove("Encoder.mlmodelc/weights/weight.bin")
        #expect(!ModelFolderCheck.isComplete(files: files, bundles: bundles, otherFiles: vocabulary))
    }

    @Test func aStagingFileFails() {
        var files = complete
        files.insert("Decoder.mlmodelc/weights/weight.bin.partial")
        #expect(!ModelFolderCheck.isComplete(files: files, bundles: bundles, otherFiles: vocabulary))
    }

    @Test func aMissingVocabularyOrBundleFails() {
        var files = complete
        files.remove("parakeet_vocab.json")
        #expect(!ModelFolderCheck.isComplete(files: files, bundles: bundles, otherFiles: vocabulary))
        #expect(!ModelFolderCheck.isComplete(files: [], bundles: bundles, otherFiles: vocabulary))
    }
}

/// FLU-29: « 42 % », « 252 Mo sur 600 Mo ».
struct DownloadProgressTextTests {
    @Test func percentWithANoBreakSpace() {
        #expect(FrenchFormat.percent(0.42) == "42\u{00A0}%")
        #expect(FrenchFormat.percent(0) == "0\u{00A0}%")
        #expect(FrenchFormat.percent(0.999) == "99\u{00A0}%")
        #expect(FrenchFormat.percent(1) == "100\u{00A0}%")
        #expect(FrenchFormat.percent(1.4) == "100\u{00A0}%")
        #expect(FrenchFormat.percent(-1) == "0\u{00A0}%")
        #expect(FrenchFormat.percent(.nan) == "0\u{00A0}%")
    }

    @Test func amountOfTheTotal() {
        #expect(DownloadProgressText.amount(fraction: 0.42, totalBytes: 600_000_000) == "252\u{00A0}Mo sur 600\u{00A0}Mo")
        #expect(DownloadProgressText.amount(fraction: 0, totalBytes: 600_000_000) == "0\u{00A0}Mo sur 600\u{00A0}Mo")
        #expect(DownloadProgressText.amount(fraction: 1, totalBytes: 600_000_000) == "600\u{00A0}Mo sur 600\u{00A0}Mo")
    }

    @Test func bytesAreTheFirstHalfOfFluidAudiosScale() {
        #expect(DownloadProgressText.byteFraction(reported: 0.21) == 0.42)
        #expect(DownloadProgressText.byteFraction(reported: 0.5) == 1)
        #expect(DownloadProgressText.byteFraction(reported: 0.9) == 1)
        #expect(DownloadProgressText.byteFraction(reported: -0.1) == 0)
        #expect(DownloadProgressText.byteFraction(reported: .infinity) == 0)
    }
}
