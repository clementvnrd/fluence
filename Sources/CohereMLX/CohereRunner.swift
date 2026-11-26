// Fluence's own code (FLU-149), beside the vendored model files.
import FluenceCore
import Foundation
import MLX

/// The one Cohere model of the process, loaded on first use and let go like Parakeet
/// (`ModelResidency`: after ten idle minutes, or at once on memory pressure — never while a
/// dictation holds it). Loading takes about 2 s and 1.9 GB; a transcription runs whole inside
/// one call of this actor, so MLX's work never hops threads halfway.
public actor CohereRunner {
    public static let shared = CohereRunner()

    private var model: CohereTranscribeModel?
    private var usersInFlight = 0
    private var lastUse: ContinuousClock.Instant?
    private var idleCheck: Task<Void, Never>?
    private var memoryPressure: DispatchSourceMemoryPressure?

    /// Where MLX finds its Metal kernels: SwiftPM does not build them, the Makefile does
    /// (`mlx.metallib` in the bundle's Resources). Must be set before the first GPU call.
    public static func useMetallib(_ url: URL) {
        GPU.metallib = url
    }

    public var isLoaded: Bool { model != nil }

    /// Loads the model from `folder` unless it is in memory already.
    public func load(from folder: URL) throws {
        guard model == nil else { return }
        let started = ContinuousClock.now
        model = try CohereTranscribeModel.fromDirectory(folder)
        lastUse = .now
        scheduleIdleCheck()
        if memoryPressure == nil { memoryPressure = Self.makeMemoryPressureSource() }
        loadSeconds = Self.seconds(ContinuousClock.now - started)
    }

    /// How long the last load took, for the log.
    public private(set) var loadSeconds: Double = 0

    /// MLX compiles most of its GPU kernels on their first use: the first transcription after a
    /// load took 7 s for 11 s of audio, the next ones under 1 s (M2). One short pass on a tone
    /// pays that once, after the load rather than on a dictation. A no-op once done.
    public func warmUp() {
        guard let model, !isWarm else { return }
        let started = ContinuousClock.now
        let tone = (0..<32_000).map { Float(sin(Double($0) * 0.05) * 0.05) }
        _ = model.transcribe(tone, language: "fr", maxTokens: { _ in 8 })
        isWarm = true
        warmUpSeconds = Self.seconds(ContinuousClock.now - started)
    }

    private var isWarm = false
    public private(set) var warmUpSeconds: Double = 0

    /// Guards (a)–(d) of `CohereGuard` around the model: near-silence is never sent, the
    /// decoder's budget follows the audio, loops and subtitle credits are taken out.
    /// - Parameters:
    ///   - samples: 16 kHz mono.
    ///   - language: Cohere's code (`CohereModel.languageCode`).
    public func transcribe(_ samples: [Float], language: String, folder: URL) throws -> String {
        guard CohereGuard.hasSpeech(samples: samples, sampleRate: 16_000) else { return "" }
        try load(from: folder)
        guard let model else { return "" }
        let raw = model.transcribe(samples, language: language, maxTokens: CohereGuard.maxTokens(audioSeconds:))
        lastUse = .now
        scheduleIdleCheck()
        return CohereGuard.clean(raw)
    }

    /// A dictation starts using the model: it stays until `endUse`.
    public func beginUse() {
        usersInFlight += 1
        idleCheck?.cancel()
        idleCheck = nil
    }

    public func endUse() {
        usersInFlight = max(0, usersInFlight - 1)
        lastUse = .now
        scheduleIdleCheck()
    }

    /// Lets the model go when `ModelResidency` allows it; the next use loads it again.
    public func unloadIfAllowed(_ trigger: ModelResidency.Trigger) {
        let state = ModelResidency.State(
            isLoaded: model != nil,
            usersInFlight: usersInFlight,
            idleSeconds: lastUse.map { Self.seconds(ContinuousClock.now - $0) }
        )
        guard ModelResidency.shouldUnload(state, trigger: trigger) else {
            if trigger == .idle { scheduleIdleCheck() }
            return
        }
        unload()
    }

    /// The model's files went to the Trash: forget it whatever the residency says.
    public func unload() {
        model = nil
        isWarm = false
        lastUse = nil
        idleCheck?.cancel()
        idleCheck = nil
        Memory.clearCache()
    }

    private func scheduleIdleCheck() {
        idleCheck?.cancel()
        let state = ModelResidency.State(
            isLoaded: model != nil,
            usersInFlight: usersInFlight,
            idleSeconds: lastUse.map { Self.seconds(ContinuousClock.now - $0) }
        )
        guard let delay = ModelResidency.nextCheck(state) else {
            idleCheck = nil
            return
        }
        idleCheck = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.unloadIfAllowed(.idle)
        }
    }

    /// Built outside the actor so the handler, which runs on a dispatch queue, does not
    /// inherit its isolation.
    private nonisolated static func makeMemoryPressureSource() -> DispatchSourceMemoryPressure {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler {
            Task { await CohereRunner.shared.unloadIfAllowed(.memoryPressure) }
        }
        source.resume()
        return source
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
