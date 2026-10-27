import AVFoundation
import FluidAudio
import Foundation
import Speech

/// One engine's outcome. Its encoded form is the `<stem>-results.json` contract, so the
/// property names are the JSON keys: keep them spelled exactly so. `wer` and `cer` stay
/// `nil` (and are then left out of the file) when there is no usable reference.
struct EngineResult: Codable, Sendable {
    let engine: String
    let detail: String
    let loadSeconds: Double
    let processSeconds: Double
    let realtimeFactor: Double
    /// Trimmed transcript as the engine produced it, punctuation and case included.
    let text: String
    var wer: Double?
    var cer: Double?
}

/// A failure the bench reports in its own words (`error: …` on stderr, exit 1).
struct BenchFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// Both engines follow the same rules so the race is fair: the very same file goes in with
// no resampling by us, the whole file is handed over at once (batch, not streaming), and
// getting a model ready is clocked apart from the transcription itself.

enum AppleEngine {

    static func transcribe(_ audio: URL, audioSeconds: Double) async throws -> EngineResult {
        // Preparation: everything up to a ready analyzer, asset download included when the
        // language pack is missing on this Mac.
        let loadStarted = Date()
        guard SpeechTranscriber.isAvailable else {
            throw BenchFailure("apple's speech transcriber is not available on this mac")
        }
        // Follows the system language; a Mac set to French is benchmarked in French.
        let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale.current)
            ?? Locale(identifier: "en-US")
        // The plain transcription preset only reports settled text. Volatile guesses would be
        // extra work that the Parakeet side never does.
        let transcriber = SpeechTranscriber(locale: locale, preset: .transcription)
        let languageTag = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == languageTag }),
           let install = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await install.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: nil)
        let loadSeconds = Date().timeIntervalSince(loadStarted)

        // Processing: feed the file, close the input, wait for the last final result.
        let processStarted = Date()
        let collector = Task { () throws -> String in
            var gathered = ""
            for try await piece in transcriber.results where piece.isFinal {
                gathered += String(piece.text.characters)
            }
            return gathered
        }
        let file = try AVAudioFile(forReading: audio)
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        let raw = try await collector.value
        let processSeconds = Date().timeIntervalSince(processStarted)

        return EngineResult(
            engine: "Apple SpeechTranscriber",
            detail: "macOS 26 · on-device · \(languageTag)",
            loadSeconds: loadSeconds,
            processSeconds: processSeconds,
            realtimeFactor: Scoring.realtimeFactor(audioSeconds: audioSeconds, processSeconds: processSeconds),
            text: raw.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}

enum ParakeetEngine {

    static func transcribe(
        _ audio: URL, audioSeconds: Double, useV2: Bool, useInt4: Bool
    ) async throws -> EngineResult {
        let version: AsrModelVersion = useV2 ? .v2 : .v3
        let precision: ParakeetEncoderPrecision = useInt4 ? .int4 : .int8

        // Preparation. FluidAudio fetches the CoreML models on the first call only and keeps
        // them in ~/Library/Application Support/FluidAudio/Models/.
        let loadStarted = Date()
        let bundle = try await AsrModels.downloadAndLoad(version: version, encoderPrecision: precision)
        let asr = AsrManager(config: .default)
        try await asr.loadModels(bundle)
        // The decoder state is set-up work, so it is made before the processing clock starts;
        // Apple does its equivalent inside its own preparation.
        var decoder = try TdtDecoderState()
        let loadSeconds = Date().timeIntervalSince(loadStarted)

        let processStarted = Date()
        let output = try await asr.transcribe(audio, decoderState: &decoder)
        let processSeconds = Date().timeIntervalSince(processStarted)

        return EngineResult(
            engine: useV2 ? "Parakeet TDT 0.6B v2" : "Parakeet TDT 0.6B v3",
            detail: "FluidAudio · CoreML on ANE · \(precision.rawValue) encoder",
            loadSeconds: loadSeconds,
            processSeconds: processSeconds,
            realtimeFactor: Scoring.realtimeFactor(audioSeconds: audioSeconds, processSeconds: processSeconds),
            text: output.text.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
