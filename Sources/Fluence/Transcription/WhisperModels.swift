import FluenceCore
import Foundation
import WhisperKit
import os

/// Process-wide WhisperKit model cache and manager.
///
/// Encapsulates WhisperKit entirely inside this actor to guarantee strict Swift 6 concurrency safety,
/// since `WhisperKit` itself is a non-Sendable class. All calls pass value types (`[Float]`, `String`).
actor WhisperModels {
    static let shared = WhisperModels()

    /// Available model variants with human-readable descriptions and sizes.
    struct Variant: Identifiable, Hashable, Sendable {
        let id: String
        let displayName: String
        let sizeDescription: String
        let isRecommended: Bool
    }

    static let availableVariants: [Variant] = [
        Variant(
            id: "openai_whisper-base",
            displayName: "Whisper Base (~140 Mo)",
            sizeDescription: "Instantané (~0.2s) • Vitesse maximale",
            isRecommended: false
        ),
        Variant(
            id: "openai_whisper-small",
            displayName: "Whisper Small (~480 Mo)",
            sizeDescription: "Rapide, imprécis en français (FLU-24)",
            isRecommended: false
        ),
        Variant(
            id: "openai_whisper-large-v3_turbo",
            displayName: "Whisper Large Turbo (~1.5 Go)",
            sizeDescription: "Plus précis, mais plus lent que le temps réel sur M1/M2 (FLU-24)",
            isRecommended: false
        )
    ]

    static let defaultVariant = "openai_whisper-small"

    /// Base folder for downloading and storing Whisper models in Application Support.
    /// `Application Support/Fluence/WhisperModels` — where Clement's build already put them.
    nonisolated static var downloadDirectory: URL {
        AppPaths.directory("WhisperModels")
    }

    /// Fast synchronous check without loading models into memory.
    nonisolated static func isDownloaded(variant: String = defaultVariant) -> Bool {
        let base = downloadDirectory
        let expectedFolder = base.appendingPathComponent("models/argmaxinc/whisperkit-coreml")
        guard FileManager.default.fileExists(atPath: expectedFolder.path) else { return false }

        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: expectedFolder.path) else {
            return false
        }
        return contents.contains { $0.contains(variant) }
    }

    private var loadedPipelines: [String: WhisperKit] = [:]
    private var loadTasks: [String: Task<Void, Error>] = [:]

    private(set) var isDownloading = false
    private(set) var downloadProgress: Double = 0.0

    /// Prepares and warms the WhisperKit pipeline for a variant.
    func prepare(variant: String = defaultVariant) async throws {
        _ = try await getOrLoadPipeline(for: variant)
    }

    /// Transcribes 16 kHz Mono Float32 samples entirely inside the actor.
    func transcribe(
        samples: [Float],
        variant: String = defaultVariant,
        language: String? = nil,
        prompt: String? = nil
    ) async throws -> String {
        let kit = try await getOrLoadPipeline(for: variant)
        let started = Date()

        var promptTokens: [Int]? = nil
        if let prompt, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let tokenizer = kit.tokenizer {
            let cleanPrompt = " " + prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            let encoded = tokenizer.encode(text: cleanPrompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            if !encoded.isEmpty {
                promptTokens = encoded
                Log.speech.info("WhisperKit: prompt conditioning active with \(encoded.count) tokens")
            }
        }

        // FLU-20: the full fallback ladder (a looping window is retried hotter, up to 1.0),
        // and long audio cut at pauses so no window runs out of tokens mid-sentence.
        func options(prompt promptTokens: [Int]?) -> DecodingOptions {
            DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: language,
                temperature: 0.0,
                temperatureIncrementOnFallback: 0.2,
                temperatureFallbackCount: 5,
                usePrefillPrompt: true,
                detectLanguage: language == nil,
                withoutTimestamps: true,
                promptTokens: promptTokens,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                noSpeechThreshold: 0.8,
                chunkingStrategy: .vad
            )
        }

        // Two passes at most: a looping result with a prompt is retried once without it, the
        // prompt being the usual cause. (A loop, not a nested function: the pipeline is not
        // Sendable and must not be captured — Swift 6.2 rejects that.)
        var text = ""
        for attempt in 0..<2 {
            if attempt == 1 {
                guard promptTokens != nil, TranscriptHealth.isDegenerate(text) else { break }
                Log.speech.error("WhisperKit: output repeated itself with a prompt — retrying without it")
            }
            let results = await kit.transcribe(
                audioArrays: [samples],
                decodeOptions: options(prompt: attempt == 0 ? promptTokens : nil)
            )
            text = results.first??
                .compactMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let elapsed = Date().timeIntervalSince(started)
        let audioSeconds = Double(samples.count) / 16_000

        Log.speech.info("""
            WhisperKit (\(language ?? "auto", privacy: .public)): \(audioSeconds, format: .fixed(precision: 1))s audio in \
            \(elapsed, format: .fixed(precision: 2))s (\(audioSeconds / max(elapsed, 0.001), format: .fixed(precision: 0))× realtime)
            """)

        return text
    }

    private func getOrLoadPipeline(for variant: String) async throws -> WhisperKit {
        if let existing = loadedPipelines[variant] {
            return existing
        }

        if let inFlight = loadTasks[variant] {
            try await inFlight.value
            if let existing = loadedPipelines[variant] {
                return existing
            }
        }

        let baseDir = Self.downloadDirectory
        let task = Task<Void, Error> { [self] in
            let started = Date()
            Log.speech.info("WhisperKit: preparing model '\(variant, privacy: .public)' in \(baseDir.path, privacy: .public)")

            let expectedFolder = baseDir.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(variant)")
            let modelFolder: URL
            if FileManager.default.fileExists(atPath: expectedFolder.path) {
                modelFolder = expectedFolder
                Log.speech.info("WhisperKit: using local model at \(expectedFolder.path, privacy: .public)")
            } else {
                modelFolder = try await WhisperKit.download(
                    variant: variant,
                    downloadBase: baseDir,
                    useBackgroundSession: false,
                    progressCallback: { progress in
                        Task { [weak self] in
                            await self?.updateProgress(progress.fractionCompleted)
                        }
                    }
                )
            }

            Log.speech.info("WhisperKit: model ready at \(modelFolder.path, privacy: .public). Loading CoreML pipeline…")

            let kit = try await WhisperKit(
                downloadBase: baseDir,
                modelFolder: modelFolder.path,
                verbose: false,
                logLevel: .none,
                prewarm: false,
                load: true,
                download: false
            )

            Log.speech.info("WhisperKit: ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            self.storePipeline(kit, for: variant)
        }

        loadTasks[variant] = task

        do {
            try await task.value
            loadTasks[variant] = nil
            if let kit = loadedPipelines[variant] {
                return kit
            }
            throw WhisperError.modelsUnavailable("WhisperKit initialization finished but pipeline not found")
        } catch {
            loadTasks[variant] = nil
            Log.speech.error("WhisperKit: initialization failed: \(error.localizedDescription)")
            throw error
        }
    }

    private func storePipeline(_ kit: WhisperKit, for variant: String) {
        loadedPipelines[variant] = kit
    }

    private func updateProgress(_ progress: Double) {
        self.downloadProgress = progress
    }
}
