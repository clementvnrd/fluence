import AVFoundation
import FluenceCore
import Foundation

/// What one engine produced for a compared recording.
struct ComparisonResult: Sendable {
    /// "Apple", "Parakeet", "Whisper", or "Wispr Flow" (set by `WisprReader`).
    let engine: String
    /// Trimmed transcript; on failure, a short French message (the engine's own error text,
    /// often English, goes to the log only).
    let text: String
    let seconds: Double
    var failed = false
    /// Wispr Flow's end-to-end latency rather than local compute time: never ranked with
    /// the local engines (FLU-48).
    var endToEnd = false
}

/// Feeds one recorded utterance to every on-device engine whose model is on disk, and times
/// each.
///
/// All get the identical buffers in one go, even though Apple's engine streams during
/// normal dictation: only then do the outputs and the timings compare like for like.
enum EngineComparison {
    /// The engines a comparison runs now: Apple, plus Parakeet and Whisper when their model is
    /// already downloaded (`ComparisonPlan`). Never a download behind the user's back.
    static func plannedEngines(whisperVariant: String) -> [ComparedEngine] {
        ComparisonPlan.engines(
            parakeetOnDisk: ParakeetModels.isDownloaded,
            whisperOnDisk: WhisperModels.isDownloaded(variant: whisperVariant)
        )
    }

    /// One engine at a time, never several at once: they would fight over the Neural Engine
    /// and the CPU and skew each other's timings. `onResult` fires after each engine, so the
    /// window can show rows as they arrive.
    static func run(
        chunks: [AudioChunk],
        engines: [ComparedEngine],
        whisperVariant: String,
        whisperLanguage: String?,
        onResult: @MainActor (ComparisonResult) -> Void = { _ in }
    ) async -> [ComparisonResult] {
        var results: [ComparisonResult] = []
        for kind in engines {
            let result: ComparisonResult
            switch kind {
            case .apple:
                result = await measure(kind.displayName, engine: AppleSpeechEngine(), chunks: chunks)
            case .parakeet:
                // Checked again at the last moment: `start()` would download a missing model.
                guard ParakeetModels.isDownloaded else { continue }
                result = await measure(kind.displayName, engine: ParakeetEngine(), chunks: chunks)
            case .whisper:
                guard WhisperModels.isDownloaded(variant: whisperVariant) else { continue }
                // Whisper loads its model on its first transcription, not in `start()`: load it
                // here, before the clock, so the row times the transcription alone.
                let engine = WhisperEngine(variant: whisperVariant, language: whisperLanguage)
                result = await measure(kind.displayName, engine: engine, chunks: chunks) {
                    try await WhisperModels.shared.prepare(variant: whisperVariant)
                }
            }
            results.append(result)
            await onResult(result)
        }
        return results
    }

    private static func measure(
        _ name: String,
        engine: any TranscriptionEngine,
        chunks: [AudioChunk],
        load: () async throws -> Void = {}
    ) async -> ComparisonResult {
        let stream: AsyncThrowingStream<TranscriptionChunk, Error>
        do {
            try await load()
            stream = try await engine.start()
        } catch {
            // The engine never ran: cancel, not finish, so nothing is transcribed on its way
            // out, and the row says it failed instead of showing a time.
            Log.speech.error("compare: \(name, privacy: .public) did not start: \(error.localizedDescription, privacy: .public)")
            Diagnostics.error("compare.engine.start", error)
            await engine.cancel()
            return ComparisonResult(engine: name, text: ComparisonRow.startFailure, seconds: 0, failed: true)
        }

        // Timed from here, after `start()`, because `start()` is where models load: whichever
        // engine the menu has picked is already warm from the live pass. Counting the load
        // would turn that menu choice into a fake speed difference.
        let started = Date()

        // Drain the stream concurrently: the final text may only be emitted inside `finish()`.
        let collector = Task<String, any Error> {
            var latest = ""
            for try await snapshot in stream {
                latest = snapshot.text
            }
            return latest
        }

        for chunk in chunks {
            await engine.feed(chunk)
        }
        await engine.finish()

        // A failure must look like one. An empty row would read as "heard nothing", and
        // that mix-up once kept an audio-format bug out of sight.
        do {
            let text = try await collector.value
            return ComparisonResult(
                engine: name,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                seconds: Date().timeIntervalSince(started)
            )
        } catch {
            Log.speech.error("compare: \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            Diagnostics.error("compare.engine.failed", error)
            // Its session is over either way; cancel is safe after finish and drops what it held.
            await engine.cancel()
            return ComparisonResult(
                engine: name,
                text: ComparisonRow.genericFailure,
                seconds: Date().timeIntervalSince(started),
                failed: true
            )
        }
    }
}
