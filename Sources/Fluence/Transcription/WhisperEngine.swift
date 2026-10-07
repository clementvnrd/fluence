import AVFoundation
import FluidAudio
import Foundation

/// Whisper transcription engine running OpenAI Whisper via WhisperKit (CoreML on Apple Silicon).
///
/// Converts speech audio chunks into 16 kHz mono Float32 PCM, delegates to `WhisperModels`,
/// and returns the transcribed text. Supports French, English, and Franglais code-switching.
actor WhisperEngine: TranscriptionEngine {
    private var samples: [Float] = []
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?
    private let converter = AudioConverter()
    private let variant: String
    private let language: String?

    init(variant: String = "openai_whisper-small", language: String? = nil) {
        self.variant = variant
        self.language = language
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        samples.removeAll(keepingCapacity: true)

        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation

        // Ensure preparation is kicked off in background without blocking capture startup
        Task { [variant] in
            try? await WhisperModels.shared.prepare(variant: variant)
        }

        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        let buffer = chunk.buffer
        guard buffer.frameLength > 0 else { return }
        do {
            samples.append(contentsOf: try converter.resampleBuffer(buffer))
        } catch {
            Log.speech.error("WhisperKit: audio conversion failed — \(error.localizedDescription)")
        }
    }

    func cancel() async {
        continuation?.finish()
        continuation = nil
        samples.removeAll(keepingCapacity: true)
    }

    func finish() async {
        defer {
            continuation?.finish()
            continuation = nil
            samples.removeAll(keepingCapacity: true)
        }

        guard samples.count >= 1_600 else {
            Log.speech.info("WhisperKit: skipped — only \(self.samples.count, privacy: .public) samples captured (< 0.1s)")
            return
        }

        do {
            let prompt = await MainActor.run {
                AutoLearningEngine.shared.buildPromptContext()
            }

            // Whisper natively supports French, English, and auto-detection (when language is nil).
            let transcribedText = try await WhisperModels.shared.transcribe(
                samples: samples,
                variant: variant,
                language: language,
                prompt: prompt
            )

            continuation?.yield(
                TranscriptionChunk(
                    text: transcribedText,
                    isFinal: true
                )
            )
        } catch {
            Log.speech.error("WhisperKit failed: \(error.localizedDescription)")
            continuation?.finish(throwing: error)
            continuation = nil
        }
    }
}
