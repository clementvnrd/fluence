import AVFoundation
import CohereMLX
import FluenceCore
import FluidAudio
import Foundation

/// Cohere Transcribe 03-2026, MLX 4-bit on the GPU (FLU-149): an option for dictation on a good
/// microphone. Batch like Parakeet: the samples pile up while the key is held and are
/// transcribed on release. Never used for meetings: it writes text on every noise clip.
actor CohereEngine: TranscriptionEngine {
    private var samples: [Float] = []
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?
    private let converter = AudioConverter()
    private var language = "fr"
    /// This dictation holds the shared model: it is not unloaded until it ends.
    private var holdsModel = false

    func preferredInputFormat() async -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        samples.removeAll(keepingCapacity: true)
        let dictationLanguage = await MainActor.run { Settings.shared.dictationLanguage }
        // `EngineDefault.active` never picks Cohere for a language it lacks.
        guard let code = CohereModel.languageCode(for: dictationLanguage) else {
            throw TranscriptionError.localeUnsupported(dictationLanguage.locale)
        }
        language = code
        let (stream, streamContinuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        continuation = streamContinuation
        if !holdsModel {
            holdsModel = true
            await CohereRunner.shared.beginUse()
        }
        // Loaded at key-down, while the user talks, as Parakeet is (about 2 s the first time).
        do {
            try await CohereModels.load()
        } catch {
            await release()
            throw error
        }
        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        guard chunk.buffer.frameLength > 0 else { return }
        do {
            samples.append(contentsOf: try converter.resampleBuffer(chunk.buffer))
        } catch {
            Log.speech.error("Cohere: audio conversion failed — \(error.localizedDescription)")
            Diagnostics.error("speech.cohere.convert", error)
        }
    }

    func finish() async {
        defer {
            continuation?.finish()
            continuation = nil
            samples.removeAll(keepingCapacity: true)
        }
        do {
            let started = Date()
            let text = try await CohereRunner.shared.transcribe(samples, language: language, folder: CohereModels.folder)
            let elapsed = Date().timeIntervalSince(started)
            let audioSeconds = Double(samples.count) / 16_000
            Log.speech.info("""
                Cohere (\(self.language, privacy: .public)): \(audioSeconds, format: .fixed(precision: 1))s audio in \
                \(elapsed, format: .fixed(precision: 2))s, \(text.count) characters
                """)
            continuation?.yield(TranscriptionChunk(text: text, isFinal: true))
        } catch {
            Log.speech.error("Cohere failed: \(String(describing: type(of: error)), privacy: .public)")
            Diagnostics.error("speech.cohere.failed", error)
            continuation?.finish(throwing: error)
            continuation = nil
        }
        await release()
    }

    func cancel() async {
        continuation?.finish()
        continuation = nil
        samples.removeAll(keepingCapacity: true)
        await release()
    }

    private func release() async {
        guard holdsModel else { return }
        holdsModel = false
        await CohereRunner.shared.endUse()
    }
}

/// Where Cohere's files live and how they are loaded (FLU-149). Downloaded only by
/// `CohereDownload`, after the user's click.
enum CohereModels {
    /// `Application Support/Fluence/CohereTranscribe`, next to the Whisper models. Not created
    /// here: an empty folder would list as an installed model; `CohereDownload` creates it.
    static var folder: URL { AppPaths.support.appendingPathComponent("CohereTranscribe", isDirectory: true) }

    /// Every file of the pinned revision at its full size. The SHA-256 was checked when the
    /// download ended; `CohereDownload.isReady` is what views read.
    static var isDownloaded: Bool {
        var sizes: [String: Int64] = [:]
        for file in CohereModel.files {
            let path = folder.appendingPathComponent(file.name).path
            if let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 {
                sizes[file.name] = size
            }
        }
        return CohereModel.isComplete(sizes: sizes)
    }

    enum LoadError: LocalizedError {
        case notDownloaded
        case kernelsMissing

        var errorDescription: String? {
            switch self {
            case .notDownloaded: "Modèle Cohere absent"
            case .kernelsMissing: "Noyaux Metal de MLX absents de l'app"
            }
        }
    }

    /// Loads the model into the shared runner (a no-op once loaded). Never downloads.
    static func load() async throws {
        guard isDownloaded else { throw LoadError.notDownloaded }
        // The Makefile puts MLX's kernels there; a bare `swift run` has none.
        guard let kernels = Bundle.main.url(forResource: "mlx", withExtension: "metallib") else {
            throw LoadError.kernelsMissing
        }
        CohereRunner.useMetallib(kernels)
        let runner = CohereRunner.shared
        guard await !runner.isLoaded else { return }
        do {
            try await runner.load(from: folder)
            let seconds = await runner.loadSeconds
            Log.speech.info("Cohere: model loaded in \(seconds, format: .fixed(precision: 1))s")
            // Not awaited: at a key-down it runs while the user talks; the transcription at
            // release waits for it on the runner.
            Task.detached(priority: .userInitiated) {
                await runner.warmUp()
                let warm = await runner.warmUpSeconds
                Log.speech.info("Cohere: kernels warmed in \(warm, format: .fixed(precision: 1))s")
            }
        } catch {
            // The loader's message names the folder, i.e. the account: the type only.
            Log.speech.error("Cohere: model load failed — \(String(describing: type(of: error)), privacy: .public)")
            Diagnostics.error("speech.cohere.load", error)
            throw error
        }
    }
}
