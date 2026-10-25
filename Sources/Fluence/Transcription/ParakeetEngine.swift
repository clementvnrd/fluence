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
    /// Everything heard since `start()`, at 16 kHz mono.
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

    /// This dictation holds the shared models: they are not unloaded until it ends (FLU-31).
    private var holdsModels = false

    func preferredInputFormat() async -> AVAudioFormat? {
        // The model's native rate; getting the microphone there is `AudioCapture`'s job.
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        samples.removeAll(keepingCapacity: true)
        let (stream, streamContinuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        continuation = streamContinuation

        // A first load is slow (about 600 MB downloaded on the very first run, seconds from
        // disk afterwards). Paying it here, before speech, means release never loses an utterance to it.
        // Since FLU-31 the models leave memory when idle, so this is also where they come back:
        // at key-down, while the user talks.
        if !holdsModels {
            holdsModels = true
            await ParakeetModels.shared.beginUse()
        }
        do {
            _ = try await ParakeetModels.shared.manager()
        } catch {
            await releaseModels()
            throw error
        }

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
            Diagnostics.error("speech.parakeet.convert", error)
        }
    }

    func finish() async {
        await transcribeAndClose()
        await releaseModels()
    }

    private func transcribeAndClose() async {
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
            let transcribeStart = Date()
            let result = try await manager.transcribe(samples, decoderState: &decoderState, language: languageHint)
            let text = await boosted(result)
            let elapsed = Date().timeIntervalSince(transcribeStart)
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
            Diagnostics.error("speech.parakeet.failed", error)
            continuation?.finish(throwing: error)
            continuation = nil
        }
    }

    func cancel() async {
        samples.removeAll(keepingCapacity: false)
        continuation?.finish()
        continuation = nil
        await releaseModels()
    }

    /// Once per dictation, whichever way it ends: `cancel()` may follow `finish()`.
    private func releaseModels() async {
        guard holdsModels else { return }
        holdsModels = false
        await ParakeetModels.shared.endUse()
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
            Diagnostics.error("speech.parakeet.vocabularyBoost", error)
            return result.text
        }
    }
}

/// The loaded Parakeet models, one copy for the whole process.
///
/// Loading is expensive — ~600 MB downloaded on first ever run, then a few seconds from
/// disk (about 20 s when Core ML recompiles after a macOS update, 0.1–0.4 s otherwise). A
/// loaded model is read-only, so every dictation and every meeting shares this one instance
/// instead of reloading per utterance. It is an actor of its own because a mutable `static`
/// on the engine would be unguarded global state in Swift 6.
///
/// FLU-31: a loaded Parakeet holds about 0.6 GB of Neural Engine memory, so it no longer stays
/// for the life of the process. `ModelResidency` decides: unloaded after ten idle minutes or on
/// memory pressure, never while a dictation (`beginUse`…`endUse`) or a meeting utterance holds
/// it. The next key-down loads it again while the user talks.
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

    // MARK: FLU-31 — residency

    private var usersInFlight = 0
    private var lastUse: ContinuousClock.Instant?
    private var idleCheck: Task<Void, Never>?
    private var memoryPressure: DispatchSourceMemoryPressure?

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

    /// Whether the transcription model is already in memory.
    var isLoaded: Bool { loaded != nil }

    /// A dictation or a meeting utterance starts using the models: they stay until `endUse`.
    func beginUse() {
        usersInFlight += 1
        idleCheck?.cancel()
        idleCheck = nil
    }

    /// The use started by `beginUse` is over; the idle clock starts again.
    func endUse() {
        usersInFlight = max(0, usersInFlight - 1)
        lastUse = .now
        scheduleIdleCheck()
    }

    private var residency: ModelResidency.State {
        ModelResidency.State(
            isLoaded: loaded != nil,
            isLoading: loading != nil && loaded == nil,
            usersInFlight: usersInFlight,
            idleSeconds: lastUse.map { Self.seconds(ContinuousClock.now - $0) }
        )
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let parts = duration.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// The continuous clock keeps counting while the Mac sleeps: an hour asleep is an hour idle.
    private func scheduleIdleCheck() {
        idleCheck?.cancel()
        guard let delay = ModelResidency.nextCheck(residency) else {
            idleCheck = nil
            return
        }
        idleCheck = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self.unloadIfAllowed(.idle)
        }
    }

    /// Frees the models when `ModelResidency` allows it. The next `manager()` loads them again.
    func unloadIfAllowed(_ trigger: ModelResidency.Trigger) async {
        guard ModelResidency.shouldUnload(residency, trigger: trigger) else {
            if trigger == .idle { scheduleIdleCheck() }
            return
        }
        let manager = loaded
        loaded = nil
        loading = nil
        // The vocabulary model goes too: it comes back with the next boosted dictation.
        vocabulary = nil
        ctcLoad = nil
        idleCheck?.cancel()
        idleCheck = nil
        lastUse = nil
        await manager?.cleanup()
        let reason = trigger == .idle ? "idle for \(Int(ModelResidency.idleLimit / 60)) min" : "memory pressure"
        Log.speech.info("Parakeet: models unloaded (\(reason, privacy: .public))")
    }

    /// The system says memory is short: let the models go if nothing is using them.
    private func watchMemoryPressure() {
        guard memoryPressure == nil else { return }
        memoryPressure = Self.makeMemoryPressureSource()
    }

    /// Built in a static, nonisolated context so the handler can't inherit the actor's
    /// isolation: it runs on a dispatch queue, where an isolated closure is a runtime trap.
    private nonisolated static func makeMemoryPressureSource() -> DispatchSourceMemoryPressure {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler {
            Task { await ParakeetModels.shared.unloadIfAllowed(.memoryPressure) }
        }
        source.resume()
        return source
    }

    /// The shared manager, loaded on first use; callers that arrive during the load wait on the
    /// same task, so nothing is downloaded twice. Each call counts as a use for the idle clock.
    func manager() async throws -> AsrManager {
        if let loaded {
            touch()
            return loaded
        }
        if let loading {
            let manager = try await loading.value
            touch()
            return manager
        }

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
            // Unloaded while it loaded (memory pressure): keep it anyway, someone is waiting.
            loaded = manager
            loading = nil
            watchMemoryPressure()
            touch()
            return manager
        } catch {
            loading = nil
            throw error
        }
    }

    /// A use outside `beginUse`/`endUse` (a prewarm, the menu's download): it restarts the
    /// idle clock, and starts it when nothing holds the models.
    private func touch() {
        lastUse = .now
        if usersInFlight == 0 { scheduleIdleCheck() }
    }
}
