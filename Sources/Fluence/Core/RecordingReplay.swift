import AVFoundation
import FluenceCore
import Foundation

/// A failed dictation's recording, kept in memory for `DictationRetry.keepSeconds` so it can
/// be transcribed again (FLU-29). Never written anywhere: it lives in this value, on the
/// controller, and is dropped on success, on expiry, or when the next one replaces it.
struct KeptRecording {
    /// 16 kHz mono Float32, `RecordingReplay.format`.
    let chunks: [AudioChunk]
    /// `ProcessInfo.systemUptime` when it was kept.
    let keptAt: TimeInterval
    /// The engine that failed on it last: *Réessayer* hands it to another one.
    var failedEngine: ComparedEngine
    let started: Date
    let releasedAt: Date?
    let target: FrontmostApp.Target?
    let targetApp: InsertTargetPolicy.App?
}

/// Runs a recording through an engine in one go, as a comparison does, and returns the text.
enum RecordingReplay {
    /// What a kept recording is stored as: Parakeet's and Whisper's own format, and one that
    /// converts cleanly to Apple's 16-bit integers when the retry goes to Apple.
    nonisolated static var format: AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    }

    /// - Parameter prepare: loads what the engine loads lazily (Whisper's pipeline), before the
    ///   audio arrives.
    nonisolated static func transcribe(
        _ chunks: [AudioChunk],
        on engine: any TranscriptionEngine,
        prepare: @Sendable () async throws -> Void = {}
    ) async throws -> String {
        do {
            try await prepare()
            let stream = try await engine.start()
            guard let format = await engine.preferredInputFormat() else {
                throw TranscriptionError.noAudioFormat
            }
            // Drained alongside: some engines only emit their final text inside `finish()`.
            let collector = Task<String, any Error> {
                var latest = ""
                for try await snapshot in stream { latest = snapshot.text }
                return latest
            }
            // Apple's analyzer takes only its own format (16-bit integers): convert, as the
            // live feed does.
            let converter = StreamConverter(output: format)
            for chunk in chunks {
                for buffer in converter.convert(chunk.buffer) {
                    await engine.feed(AudioChunk(buffer: buffer))
                }
            }
            for buffer in converter.drain() {
                await engine.feed(AudioChunk(buffer: buffer))
            }
            await engine.finish()
            return try await collector.value.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            await engine.cancel()
            throw error
        }
    }
}
