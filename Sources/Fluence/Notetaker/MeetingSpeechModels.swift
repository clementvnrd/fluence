import FluenceCore
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

    /// The four models a meeting uses.
    enum Kind: CaseIterable {
        case speech, voiceActivity, echo, speakers

        var name: String {
            switch self {
            case .speech: "Reconnaissance vocale"
            case .voiceActivity: "Détection de la voix"
            case .echo: "Annulation d'écho"
            case .speakers: "Séparation des intervenants"
            }
        }

        /// Approximate download sizes, in megabytes.
        var megabytes: Int {
            switch self {
            case .speech: 600
            case .voiceActivity: 2
            case .echo: 19
            case .speakers: 30
            }
        }

        /// Best effort: FluidAudio's cache folders are checked, not their contents.
        var isPresent: Bool {
            switch self {
            case .speech: ParakeetModels.isDownloaded
            case .voiceActivity: MeetingSpeechModels.present(.vad)
            case .echo: MeetingSpeechModels.present(.localVqe)
            case .speakers: MeetingSpeechModels.present(.diarizer)
            }
        }
    }

    nonisolated static var models: [MeetingReadiness.Model] {
        Kind.allCases.map { .init(name: $0.name, megabytes: $0.megabytes, isPresent: $0.isPresent) }
    }

    /// Human-readable names of the models a first meeting would download, with sizes.
    nonisolated static var missingDownloads: [String] {
        Kind.allCases.filter { !$0.isPresent }.map { "\($0.name.lowercased()) (~\($0.megabytes) Mo)" }
    }

    // MARK: - Downloading ahead of a meeting (FLU-45)

    /// Fetches every missing model before any call, reporting 0…1 across all of them
    /// (weighted by size). Each one lands in the folder its loader reads, so the first
    /// meeting finds it and downloads nothing.
    ///
    /// Parakeet and the diarizer are only downloaded, not loaded: loading Parakeet costs
    /// about 600 MB of memory, and the diarizer is used once, after the call. The voice
    /// detector and the echo canceller (21 MB together) have no download-only call that
    /// picks the same variant, so they are loaded through the same path a meeting uses,
    /// and stay ready for it.
    func downloadMissing(progress: @escaping @Sendable (Double) -> Void) async throws {
        let missing = Kind.allCases.filter { !$0.isPresent }
        let total = Double(max(1, missing.reduce(0) { $0 + $1.megabytes }))
        let root = MLModelConfigurationUtils.defaultModelsDirectory()
        var done = 0.0

        for kind in missing {
            let base = done
            let share = Double(kind.megabytes) / total
            let report: ProgressHandler = { progress(base + share * $0.fractionCompleted) }
            switch kind {
            case .speech:
                // Parakeet Ultra, the version `ParakeetModels` loads, through the same call as
                // dictation's download (FLU-29): bundles and vocabulary, which `isDownloaded`
                // requires both.
                try await ParakeetModels.download { progress(base + share * $0) }
            case .speakers:
                // The offline diarizer, as `MeetingFinalizer` uses it.
                try await ModelHub.download(.diarizer, to: root, variant: "offline", progressHandler: report)
            case .voiceActivity:
                _ = try await vadManager()
            case .echo:
                _ = try await echoCanceller()
            }
            done += share
            progress(done)
        }
    }
}
