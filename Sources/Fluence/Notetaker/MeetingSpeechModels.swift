import FluidAudio
import Foundation

/// The on-device models a meeting needs, loaded once per process and shared by both
/// channels. Parakeet itself comes from `ParakeetModels.shared`, the same instance
/// dictation uses.
///
/// Every model is fetched from Hugging Face by FluidAudio on first use — the only network
/// traffic the Notetaker ever causes. `missingDownloads` lets the UI say so beforehand.
actor MeetingSpeechModels {
    static let shared = MeetingSpeechModels()

    private var vad: VadManager?
    private var vadTask: Task<VadManager, Error>?
    private var vqe: LocalVqeManager?
    private var vqeTask: Task<LocalVqeManager, Error>?

    /// Silero VAD (FluidAudio `VadManager`). The threshold here is unused: utterances are
    /// cut by `UtteranceSegmenter` from the raw probabilities.
    func vadManager() async throws -> VadManager {
        if let vad { return vad }
        if let vadTask { return try await vadTask.value }
        let task = Task { try await VadManager(config: VadConfig(defaultThreshold: 0.5)) }
        vadTask = task
        do {
            let manager = try await task.value
            vad = manager
            return manager
        } catch {
            vadTask = nil
            throw error
        }
    }

    /// LocalVQE echo canceller (beta). v1.3 with 256 ms calls: the pipeline feeds whole
    /// 4096-sample hops, so the larger chunk costs no latency and is ~2.5× cheaper.
    func echoCanceller() async throws -> LocalVqeManager {
        if let vqe { return vqe }
        if let vqeTask { return try await vqeTask.value }
        let task = Task { try await LocalVqeManager(config: LocalVqeConfig(variant: .v13, chunk: .batch256ms)) }
        vqeTask = task
        do {
            let manager = try await task.value
            vqe = manager
            return manager
        } catch {
            vqeTask = nil
            throw error
        }
    }

    // MARK: - What still has to be downloaded

    private static func present(_ repo: Repo) -> Bool {
        FileManager.default.fileExists(atPath: MLModelConfigurationUtils.defaultModelsDirectory(for: repo).path)
    }

    /// Human-readable names of the models a first meeting would download, with sizes.
    /// Best effort: it checks FluidAudio's cache folders, not their contents.
    nonisolated static var missingDownloads: [String] {
        var missing: [String] = []
        if !ParakeetModels.isDownloaded { missing.append("reconnaissance vocale (~470 Mo)") }
        if !present(.vad) { missing.append("détection de la voix (~2 Mo)") }
        if !present(.localVqe) { missing.append("annulation d'écho (~19 Mo)") }
        if !present(.diarizer) { missing.append("séparation des intervenants (~30 Mo)") }
        return missing
    }
}
