import Foundation

/// A stretch of one channel to transcribe as a unit, in samples of that channel's
/// timeline (which is meeting time × sample rate).
public struct Utterance: Sendable, Hashable {
    public var startSample: Int
    public var endSample: Int

    public init(startSample: Int, endSample: Int) {
        self.startSample = startSample
        self.endSample = endSample
    }

    public var sampleCount: Int { endSample - startSample }
}

/// Turns a stream of per-hop voice probabilities (Silero VAD, one value per fixed hop)
/// into utterances for the recogniser.
///
/// Why per utterance rather than fixed windows: Parakeet on fixed windows drops, glues or
/// duplicates words at the seams (FluidAudio documents this). Cutting at pauses avoids
/// seams inside words, and a cap keeps each call inside the model's comfortable range.
///
/// Rules (Silero-style hysteresis):
/// - Speech starts at a hop whose probability is ≥ `threshold`.
/// - While in speech, a hop below `negativeThreshold` is silence; any hop at or above it
///   counts as speech (so a dip between the two thresholds never ends an utterance).
/// - Speech ends once `minSilence` of consecutive silence has accumulated; the utterance
///   ends where that silence began.
/// - An utterance reaching `maxDuration` is cut at the start of its least probable hop in
///   the second half (ties: the latest), and speech continues from there as a new one.
/// - Utterances with less than `minSpeech` of speech are dropped.
/// - `padding` is added on both sides, clamped to the samples seen so far and never
///   reaching back before the previous utterance's end.
public struct UtteranceSegmenter: Sendable {
    public struct Config: Sendable {
        public var sampleRate: Int = 16_000
        /// Samples per probability. FluidAudio's Silero model works on 4096-sample hops.
        public var hopSamples: Int = 4_096
        public var threshold: Float = 0.5
        public var negativeThreshold: Float = 0.35
        public var minSilence: TimeInterval = 0.5
        public var minSpeech: TimeInterval = 0.25
        public var maxDuration: TimeInterval = 20
        public var padding: TimeInterval = 0.1

        public init() {}
    }

    public let config: Config
    private var hop = 0
    private var inSpeech = false
    private var startHop = 0
    private var silentHops = 0
    private var probabilities: [Float] = []
    private var lastEnd = 0

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Samples covered so far.
    public var processedSamples: Int { hop * config.hopSamples }

    /// Whether the last hop left the segmenter inside speech.
    public var isInSpeech: Bool { inSpeech }

    /// Feeds the probability for the next hop. Returns any utterance that closed.
    public mutating func push(_ probability: Float) -> [Utterance] {
        defer { hop += 1 }
        var closed: [Utterance] = []

        if !inSpeech {
            if probability >= config.threshold {
                inSpeech = true
                startHop = hop
                silentHops = 0
                probabilities = [probability]
            }
            return closed
        }

        probabilities.append(probability)
        if probability < config.negativeThreshold {
            silentHops += 1
        } else {
            silentHops = 0
        }

        let minSilenceHops = max(1, hops(config.minSilence))
        if silentHops >= minSilenceHops {
            let endHop = hop + 1 - silentHops
            if let utterance = finish(fromHop: startHop, toHop: endHop, totalHops: hop + 1) {
                closed.append(utterance)
            }
            inSpeech = false
            probabilities = []
            return closed
        }

        let maxHops = max(2, hops(config.maxDuration))
        if probabilities.count >= maxHops {
            // Cut at the least probable hop in the second half; latest on ties.
            let half = probabilities.count / 2
            var cut = half
            for index in half..<probabilities.count where probabilities[index] <= probabilities[cut] {
                cut = index
            }
            cut = max(cut, 1)
            let cutHop = startHop + cut
            if let utterance = finish(fromHop: startHop, toHop: cutHop, totalHops: hop + 1, padEnd: false) {
                closed.append(utterance)
            }
            probabilities = Array(probabilities[cut...])
            startHop = cutHop
            silentHops = 0
        }
        return closed
    }

    /// Closes any open utterance at the end of the stream.
    public mutating func finish() -> [Utterance] {
        guard inSpeech else { return [] }
        inSpeech = false
        let endHop = hop - silentHops
        probabilities = []
        return finish(fromHop: startHop, toHop: endHop, totalHops: hop).map { [$0] } ?? []
    }

    private func hops(_ seconds: TimeInterval) -> Int {
        Int((seconds * Double(config.sampleRate) / Double(config.hopSamples)).rounded())
    }

    private mutating func finish(fromHop: Int, toHop: Int, totalHops: Int, padEnd: Bool = true) -> Utterance? {
        let speechSamples = (toHop - fromHop) * config.hopSamples
        guard Double(speechSamples) >= config.minSpeech * Double(config.sampleRate) else { return nil }
        let pad = Int(config.padding * Double(config.sampleRate))
        let start = max(lastEnd, fromHop * config.hopSamples - pad, 0)
        let end = min(toHop * config.hopSamples + (padEnd ? pad : 0), totalHops * config.hopSamples)
        guard end > start else { return nil }
        lastEnd = end
        return Utterance(startSample: start, endSample: end)
    }
}
