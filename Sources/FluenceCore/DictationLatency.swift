import Foundation

/// The timings of one dictation's tail, from the end of speech to the text (FLU-31). Numbers
/// only: nothing here can hold a word of what was said.
public struct DictationLatency: Equatable, Sendable {
    /// Key-up → microphone closed.
    public var postRoll: Double
    /// Microphone closed and audio drained → the engine's final text.
    public var engine: Double
    /// Key-up → text inserted.
    public var keyUpToText: Double
    /// Estimated end of speech (the last window above room tone) → text inserted. Nil when
    /// the capture had no timing.
    public var speechEndToText: Double?
    /// How long the key was held.
    public var audioSeconds: Double

    public init(postRoll: Double, engine: Double, keyUpToText: Double, speechEndToText: Double?, audioSeconds: Double) {
        self.postRoll = postRoll
        self.engine = engine
        self.keyUpToText = keyUpToText
        self.speechEndToText = speechEndToText
        self.audioSeconds = audioSeconds
    }

    public enum Metric: Sendable {
        case postRoll, engine, keyUpToText, speechEndToText
    }

    public func value(_ metric: Metric) -> Double? {
        switch metric {
        case .postRoll: postRoll
        case .engine: engine
        case .keyUpToText: keyUpToText
        case .speechEndToText: speechEndToText
        }
    }
}

/// The last dictations' timings, for the budgets FLU-31 sets: end of speech → text at most
/// 250 ms at the median for dictations up to 10 s, 400 ms for 44 s. In memory only.
public struct LatencyCounter: Sendable {
    public static let capacity = 200
    /// Up to here a dictation counts as short for the budget.
    public static let shortDictation: Double = 10

    public private(set) var samples: [DictationLatency] = []

    public init() {}

    public var count: Int { samples.count }

    public mutating func record(_ sample: DictationLatency) {
        samples.append(sample)
        if samples.count > Self.capacity { samples.removeFirst(samples.count - Self.capacity) }
    }

    /// The nearest-rank percentile (0…1) of `metric`, over the dictations whose length falls
    /// in `audio`; nil when there is none.
    public func percentile(_ p: Double, of metric: DictationLatency.Metric, audio: ClosedRange<Double>? = nil) -> Double? {
        let values = samples
            .filter { audio?.contains($0.audioSeconds) ?? true }
            .compactMap { $0.value(metric) }
            .sorted()
        guard !values.isEmpty else { return nil }
        let rank = Int((min(max(p, 0), 1) * Double(values.count)).rounded(.up))
        return values[max(0, min(values.count - 1, rank - 1))]
    }

    public func median(of metric: DictationLatency.Metric, audio: ClosedRange<Double>? = nil) -> Double? {
        percentile(0.5, of: metric, audio: audio)
    }

    public func count(audio: ClosedRange<Double>) -> Int {
        samples.count { audio.contains($0.audioSeconds) }
    }

    public static let short: ClosedRange<Double> = 0...shortDictation
    public static let long: ClosedRange<Double> = shortDictation.nextUp...Double.greatestFiniteMagnitude
}
