import AVFoundation
import Foundation

/// What one engine produced for a compared recording.
struct ComparisonResult: Sendable {
    /// "Apple", "Parakeet", or "Wispr Flow" (set by `WisprReader`).
    let engine: String
    /// Trimmed transcript; on failure, a "⚠️" message instead.
    let text: String
    let seconds: Double
}

/// Feeds one recorded utterance to Apple's engine and to Parakeet, and times each.
///
/// Both get the identical buffers in one go, even though Apple's engine streams during
/// normal dictation: only then do the outputs and the timings compare like for like.
enum EngineComparison {
    /// One engine at a time, never both at once: they would fight over the Neural Engine and
    /// the CPU and skew each other's timings. `onResult` fires after each engine, so the
    /// window can show rows as they arrive.
    static func run(
        chunks: [AudioChunk],
        onResult: @MainActor (ComparisonResult) -> Void = { _ in }
    ) async -> [ComparisonResult] {
        let engines: [(name: String, engine: any TranscriptionEngine)] = [
            ("Apple", AppleSpeechEngine()),
            ("Parakeet", ParakeetEngine()),
        ]
        var results: [ComparisonResult] = []
        for (name, engine) in engines {
            let result = await measure(name, engine: engine, chunks: chunks)
            results.append(result)
            await onResult(result)
        }
        return results
    }

    private static func measure(
        _ name: String,
        engine: any TranscriptionEngine,
        chunks: [AudioChunk]
    ) async -> ComparisonResult {
        do {
            let stream = try await engine.start()

            // Timed from here, after `start()`, because `start()` is where models load:
            // for Parakeet that's ~600 MB on a cold first run — and whichever engine the
            // menu has picked is already warm from the live pass. Counting the load would turn
            // that menu choice into a fake speed difference.
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
            let text: String
            do {
                text = try await collector.value
            } catch {
                Log.speech.error("compare: \(name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                text = "⚠️ \(error.localizedDescription)"
            }

            return ComparisonResult(
                engine: name,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                seconds: Date().timeIntervalSince(started)
            )
        } catch {
            Log.speech.error("compare: \(name, privacy: .public) did not start: \(error.localizedDescription, privacy: .public)")
            await engine.finish()
            return ComparisonResult(engine: name, text: "⚠️ \(error.localizedDescription)", seconds: 0)
        }
    }
}
