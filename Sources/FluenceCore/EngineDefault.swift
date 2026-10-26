import Foundation

/// Which speech engine a dictation runs on (FLU-29, default decided on FLU-39).
///
/// French and Auto default to Parakeet Ultra: on the French bench it gets about one word in nine
/// wrong on technical vocabulary where Apple gets one in four (`docs/SPEECH-MODELS.md`). Other
/// languages keep Apple, which ships with macOS. Parakeet is only ever *used* once its model is
/// complete on disk, downloaded with the user's consent: until then Apple listens, so no
/// dictation ever waits behind a 600 MB download.
public enum EngineDefault {
    /// The engine a language gets when the user never picked one.
    public static func preferred(for language: DictationLanguage) -> ComparedEngine {
        switch language {
        case .french, .auto: .parakeet
        default: .apple
        }
    }

    /// The engine the user sees as selected: their own choice, or the language's default.
    public static func selected(chosen: ComparedEngine?, language: DictationLanguage) -> ComparedEngine {
        chosen ?? preferred(for: language)
    }

    /// The engine that runs at key-down: the selected one, except Parakeet while its model is
    /// not complete on disk, when Apple stands in.
    public static func active(chosen: ComparedEngine?, language: DictationLanguage, parakeetReady: Bool) -> ComparedEngine {
        let selected = selected(chosen: chosen, language: language)
        return selected == .parakeet && !parakeetReady ? .apple : selected
    }

    /// Whether Apple is standing in for a Parakeet that is not on disk yet: the download card in
    /// Réglages › Transcription and the capsule's progress say so.
    public static func isWaitingForParakeet(chosen: ComparedEngine?, language: DictationLanguage, parakeetReady: Bool) -> Bool {
        selected(chosen: chosen, language: language) == .parakeet && !parakeetReady
    }

    /// Whether the onboarding shows its « Transcription » step: dictation in French or Auto, and
    /// Parakeet Ultra not on disk yet.
    public static func offersParakeetStep(language: DictationLanguage, parakeetReady: Bool) -> Bool {
        (language == .french || language == .auto) && !parakeetReady
    }
}

/// Whether a downloaded Core ML model folder is complete enough to load (FLU-29).
///
/// FluidAudio writes each file through a `.partial` staging file and moves it in place once
/// whole, one file at a time; a download cancelled between two files leaves a bundle with its
/// `coremldata.bin` but no weights, which the old « Encoder.mlmodelc exists » test took for a
/// finished download — and the next dictation then waited on the rest of it.
public enum ModelFolderCheck {
    /// The files every compiled bundle of the Parakeet family carries (checked on the Ultra
    /// layout FluidAudio 0.17 downloads).
    public static let bundleFiles = ["coremldata.bin", "weights/weight.bin"]

    /// - Parameters:
    ///   - files: every regular file under the model folder, as paths relative to it.
    ///   - bundles: the `.mlmodelc` bundles the model needs.
    ///   - otherFiles: plain files it needs too (the vocabulary).
    public static func isComplete(files: Set<String>, bundles: Set<String>, otherFiles: Set<String>) -> Bool {
        guard !files.contains(where: { $0.hasSuffix(".partial") }) else { return false }
        for bundle in bundles {
            for part in bundleFiles where !files.contains(bundle + "/" + part) { return false }
        }
        return otherFiles.isSubset(of: files)
    }
}

/// A model download's progress as the UI shows it: « 42 % », « 252 Mo sur 600 Mo ».
public enum DownloadProgressText {
    /// FluidAudio's repo download reports bytes on the first half of its scale and keeps the
    /// second half for a Core ML compile that a download-only call never runs: the bytes'
    /// share is the reported value over that half, clamped to 0…1.
    public static func byteFraction(reported: Double, downloadPhaseWeight: Double = 0.5) -> Double {
        guard reported.isFinite, downloadPhaseWeight > 0 else { return 0 }
        return min(1, max(0, reported / downloadPhaseWeight))
    }

    /// « 252 Mo sur 600 Mo »: both in megabytes, whole, the done part rounded down.
    public static func amount(fraction: Double, totalBytes: Int64) -> String {
        let clamped = fraction.isFinite ? min(1, max(0, fraction)) : 0
        let total = Double(max(0, totalBytes)) / 1e6
        let done = Int((total * clamped).rounded(.down))
        return "\(done)" + FrenchFormat.space + "Mo sur " + "\(Int(total.rounded()))" + FrenchFormat.space + "Mo"
    }
}

extension FrenchFormat {
    /// « 42 % », with the non-breaking space French puts before the sign. Rounded down, so a
    /// download never reads « 100 % » before it is over.
    public static func percent(_ fraction: Double) -> String {
        let clamped = fraction.isFinite ? min(1, max(0, fraction)) : 0
        return "\(Int((clamped * 100).rounded(.down)))" + space + "%"
    }
}
