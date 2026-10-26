import AVFoundation
import Foundation

/// One buffer of captured audio, on its way to an engine.
///
/// `AVAudioPCMBuffer` is not `Sendable`, hence `@unchecked`. That is sound only because
/// `AudioCapture` copies each tap callback into a buffer of its own and never touches it again
/// once sent: `AVAudioEngine` reuses the tap's buffer as soon as the callback returns, so the
/// tap's own buffer must never be wrapped in an `AudioChunk`.
struct AudioChunk: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    /// Host-clock seconds of the first sample, when the capture knows it (FLU-31: the
    /// post-roll compares it with the moment the key came up). Nil after conversion.
    var captureTime: TimeInterval? = nil
}

/// What an engine reports back.
struct TranscriptionChunk: Sendable {
    /// The whole transcript of the session so far, never a delta: engines revise words they
    /// already reported, so a consumer replaces its copy rather than appending.
    let text: String
    /// Set on the session's last snapshot.
    let isFinal: Bool
}

/// The seam that keeps Fluence engine-agnostic.
///
/// Every engine is an actor conforming to it: Apple's `SpeechAnalyzer` (the default, part of
/// macOS 26, nothing to download), Parakeet through FluidAudio on Core ML and the Neural Engine,
/// and Whisper through WhisperKit. Another engine is one more conformance.
protocol TranscriptionEngine: Actor {
    /// The audio format the engine wants; `AudioCapture` converts the microphone to it. Nil
    /// when the engine has none the app can use, and the controller fails with `noAudioFormat`.
    func preferredInputFormat() async -> AVAudioFormat?

    /// Loads the model or assets and opens a session. The stream ends after `finish()` or `cancel()`.
    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error>

    /// One buffer, already converted to `preferredInputFormat()`.
    func feed(_ chunk: AudioChunk) async

    /// No more audio: the final snapshot goes out, then the stream closes.
    func finish() async

    /// Close the session and throw away what it heard: no final result, no transcription
    /// pass. For a dictation that was cancelled, or that the silence gate turned away.
    /// Safe to call more than once, and after `finish()`.
    func cancel() async
}

enum TranscriptionError: LocalizedError {
    case localeUnsupported(Locale)
    case modelInstallFailed(String)
    case noAudioFormat
    case notRunning

    var errorDescription: String? {
        switch self {
        case .localeUnsupported(let locale):
            "Dictée indisponible sur ce Mac en \(locale.identifier)"
        case .modelInstallFailed(let detail):
            "Modèle vocal non installé : \(detail)"
        case .noAudioFormat:
            "Format audio non pris en charge par le moteur"
        case .notRunning:
            "Moteur de transcription arrêté"
        }
    }
}
