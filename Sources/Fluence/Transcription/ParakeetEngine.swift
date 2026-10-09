import AVFoundation
import FluenceCore
import FluidAudio
import Foundation

/// NVIDIA's Parakeet TDT 0.6B family (the Ultra weights, see `ParakeetModels.version`) through
/// FluidAudio, on Core ML and the Neural Engine.
///
/// Batch by design: samples pile up while the key is held and are transcribed in one pass on
/// release. At about a hundred times real time (twelve seconds of speech in roughly 0.12 s) that
/// pass goes unnoticed in push-to-talk; what it costs is the live HUD text the Apple engine
/// shows. FluidAudio's sliding-window manager would give live partials, at the price of a much
/// harder integration, and is not used.
actor ParakeetEngine: TranscriptionEngine {
    private var samples: [Float] = []
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?

    // MARK: FLU-5 text
    /// The chosen language as a script hint for v3's decoder; nil in Auto (v3 detects).
    private var languageHint: Language?
    /// Dictionary phrases to rescore against, when vocabulary boosting is on and its model
    /// is on disk. Empty otherwise.
    private var boostPhrases: [String] = []

    /// Out of the box it produces 16 kHz mono Float32, the format Parakeet was trained on.
    private let converter = AudioConverter()

    func preferredInputFormat() async -> AVAudioFormat? {
        // The model's native rate; getting the microphone there is `AudioCapture`'s job.
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        samples.removeAll(keepingCapacity: true)

        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation

        // A first load is slow (about 600 MB downloaded on the very first run, seconds from
        // disk afterwards). Paying it here, before speech, means release never loses an utterance to it.
        _ = try await ParakeetModels.shared.manager()

        // MARK: FLU-5 text — read once per dictation, on the main actor where they live.
        let (language, boost, phrases) = await MainActor.run {
            (Settings.shared.dictationLanguage, Settings.shared.parakeetVocabularyBoost, DictionaryStore.shared.biasPhrases)
        }
        languageHint = language.code.flatMap(Language.init(rawValue:))
        // Never downloaded here: a 100 MB fetch on a dictation would look like a hang. The
        // Settings toggle downloads it; until then boosting simply doesn't run.
        boostPhrases = boost && ParakeetModels.isVocabularyModelDownloaded ? phrases : []
        if !boostPhrases.isEmpty {
            // Warm while the user speaks, so release only pays for the rescoring itself.
            let phrases = boostPhrases
            Task.detached(priority: .utility) {
                _ = try? await ParakeetModels.shared.vocabularySession(for: phrases)
            }
        }

        return stream
    }

    func feed(_ chunk: AudioChunk) async {
        let buffer = chunk.buffer
        guard buffer.frameLength > 0 else { return }

        // `AsrManager.transcribe` takes [Float] at face value: no resampling, no rate check,
        // and audio at another rate comes back as confident nonsense without any error. Compare
        // mode captures in Apple's format (Int16, 8 or 16 kHz), so every buffer goes through
        // FluidAudio's converter, which normalizes anything to 16 kHz mono Float32; its Int16
        // path is the same x / 32 768 a hand-written conversion would use.
        do {
            samples.append(contentsOf: try converter.resampleBuffer(buffer))
        } catch {
            Log.speech.error("Parakeet: audio conversion failed — \(error.localizedDescription)")
        }
    }

    func finish() async {
        defer {
            continuation?.finish()
            continuation = nil
            samples.removeAll(keepingCapacity: true)
        }

        // The encoder needs a minimum of input, and a key tap under 0.1 s holds no speech. Said in
        // the log because the wrong-rate bug above once showed only as quick empty results.
        guard samples.count >= 1_600 else {
            Log.speech.info("Parakeet: skipped — only \(self.samples.count) samples captured (< 0.1s)")
            return
        }

        do {
            let manager = try await ParakeetModels.shared.manager()
            var decoderState = try TdtDecoderState()
            let started = Date()
            let result = try await manager.transcribe(samples, decoderState: &decoderState, language: languageHint)
            let text = await boosted(result)
            let elapsed = Date().timeIntervalSince(started)
            let audioSeconds = Double(samples.count) / 16_000

            Log.speech.info("""
                Parakeet: \(audioSeconds, format: .fixed(precision: 1))s audio in \
                \(elapsed, format: .fixed(precision: 2))s \
                (\(audioSeconds / max(elapsed, 0.001), format: .fixed(precision: 0))× realtime)
                """)

            continuation?.yield(
                TranscriptionChunk(
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                    isFinal: true
                )
            )
        } catch {
            Log.speech.error("Parakeet failed: \(error.localizedDescription)")
            continuation?.finish(throwing: error)
            continuation = nil
        }
    }

    func cancel() async {
        samples.removeAll(keepingCapacity: false)
        continuation?.finish()
        continuation = nil
    }

    // MARK: FLU-5 text

    /// The transcript rescored against the dictionary, or as transcribed.
    ///
    /// FluidAudio's vocabulary boosting (CTC keyword spotting + constrained rescoring):
    /// a second, small CTC model listens to the same audio for the dictionary's words and
    /// replaces a transcribed word only when the acoustic evidence for the dictionary word
    /// is stronger. Every failure is absorbed — boosting must never cost a transcript.
    private func boosted(_ result: ASRResult) async -> String {
        guard !boostPhrases.isEmpty, let timings = result.tokenTimings, !timings.isEmpty else {
            return result.text
        }
        do {
            let session = try await ParakeetModels.shared.vocabularySession(for: boostPhrases)
            guard let rescored = await session.rescore(text: result.text, tokenTimings: timings, audioSamples: samples) else {
                return result.text
            }
            let applied = rescored.replacements.count { $0.shouldReplace }
            Log.speech.info("Parakeet: vocabulary boost — \(applied, privacy: .public) replacement(s)")
            return rescored.text
        } catch {
            Log.speech.error("Parakeet: vocabulary boost unavailable — \(error.localizedDescription, privacy: .public)")
            return result.text
        }
    }
}

/// The loaded Parakeet models, one copy for the whole process.
///
/// Loading is expensive — ~600 MB downloaded on first ever run, then a few seconds from
/// disk, paid once per process. A loaded model is read-only, so every dictation and every
/// meeting shares this one instance instead of reloading per utterance. It is an actor of its
/// own because a mutable `static` on the engine would be unguarded global state in Swift 6.
actor ParakeetModels {
    static let shared = ParakeetModels()

    /// Parakeet Ultra (moondream's post-training of NVIDIA's v3): same architecture,
    /// 25 languages and decoding as v3, better weights. On the French bench (FLU-24,
    /// `docs/SPEECH-MODELS.md`) it is level with v3 on clean speech, better through a
    /// distant webcam mic (11.5 % vs 14.7 % of words wrong in tech dictations), and faster.
    static let version: AsrModelVersion = .ultra
    /// FluidAudio's cache folder for `version`.
    nonisolated static let folder = "parakeet-ultra"

    /// Whether the transcription model is on disk, without loading it. The menu asks while it
    /// draws, hence `nonisolated` and a file check: an in-memory flag would read false after
    /// every launch and misreport the download.
    nonisolated static var isDownloaded: Bool {
        let encoder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models/\(folder)/Encoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path)
    }

    private var loaded: AsrManager?
    private var loading: Task<AsrManager, Error>?

    // MARK: FLU-5 text — vocabulary boosting

    /// The CTC model behind vocabulary boosting (Parakeet CTC 110M, ~100 MB), separate from
    /// the transcription model and only fetched when the user turns boosting on.
    nonisolated static var isVocabularyModelDownloaded: Bool {
        CtcModels.modelsExist(at: CtcModels.defaultCacheDirectory(for: .ctc110m))
    }

    private var ctcLoad: Task<CtcModels, Error>?
    /// One session per phrase list: building it tokenizes every term, so it is reused until
    /// the dictionary changes.
    private var vocabulary: (phrases: [String], session: Task<VocabularyBoostingSession, Error>)?

    /// Downloads (once) and loads the CTC model. Called from Settings when boosting is
    /// turned on, so the download is something the user asked for and can watch.
    func loadVocabularyModel() async throws -> CtcModels {
        if let ctcLoad { return try await ctcLoad.value }
        let task = Task { try await CtcModels.downloadAndLoad(variant: .ctc110m) }
        ctcLoad = task
        do {
            return try await task.value
        } catch {
            ctcLoad = nil
            throw error
        }
    }

    func vocabularySession(for phrases: [String]) async throws -> VocabularyBoostingSession {
        if let vocabulary, vocabulary.phrases == phrases { return try await vocabulary.session.value }
        let task = Task<VocabularyBoostingSession, Error> {
            let models = try await self.loadVocabularyModel()
            let context = CustomVocabularyContext(terms: phrases.map { CustomVocabularyTerm(text: $0) })
            return try await VocabularyBoostingSession(vocabulary: context, ctcModels: models)
        }
        vocabulary = (phrases, task)
        do {
            return try await task.value
        } catch {
            if vocabulary?.phrases == phrases { vocabulary = nil }
            throw error
        }
    }

    var isLoaded: Bool { loaded != nil }

    /// The shared manager, loaded on first use; callers that arrive during the load wait on the
    /// same task, so nothing is downloaded twice.
    func manager() async throws -> AsrManager {
        if let loaded { return loaded }
        if let loading { return try await loading.value }

        let task = Task<AsrManager, Error> {
            // `os.Logger` only takes an interpolation literal, so the ternary goes in a local.
            let stage = Self.isDownloaded
                ? "loading models from disk"
                : "downloading models (~600 MB, one time)"
            Log.speech.info("Parakeet: \(stage, privacy: .public)")
            let started = Date()
            let models = try await AsrModels.downloadAndLoad(version: Self.version)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            Log.speech.info("Parakeet: models ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s")
            return manager
        }
        loading = task

        // A failure is not remembered: after a passing network error, the next dictation
        // simply tries again.
        do {
            let manager = try await task.value
            loaded = manager
            return manager
        } catch {
            loading = nil
            throw error
        }
    }
}
