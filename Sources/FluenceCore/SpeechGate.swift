import Foundation

/// Keeps silence and stray key taps away from the speech engine.
///
/// Speech models hallucinate on near-silence — room tone comes back as "Thank you." or a
/// line of dictionary terms — and a quarter-second tap of the key is never a dictation. The
/// gate is deliberately crude, energy over 20 ms windows: it only has to tell "somebody
/// spoke" from "nobody did", and it must never be the reason a quiet speaker loses a word.
public struct SpeechGate: Sendable {
    public enum Verdict: Equatable, Sendable {
        case accepted
        /// Shorter than any real utterance: an accidental tap.
        case tooShort(seconds: Double)
        /// Long enough, but nothing in it rose above room tone.
        case silent
    }

    /// The shortest hold worth transcribing.
    public static let minimumDuration: Double = 0.25
    /// A 20 ms window at or above this RMS (about -55 dBFS) counts as sound. Well under quiet
    /// speech at arm's length, well over a built-in mic's noise floor.
    public static let activityThreshold: Float = 0.0018
    /// How much sound it takes to call the recording speech — a short syllable's worth.
    public static let minimumActivity: Double = 0.08

    private static let window: Double = 0.02

    public private(set) var duration: Double = 0
    public private(set) var activeDuration: Double = 0

    private var windowEnergy: Float = 0
    private var windowFrames = 0

    public init() {}

    /// True from the first moment the recording contains speech-level sound. Audio held
    /// back before this is released to the engine all at once, in order.
    public var hasSpeech: Bool { activeDuration >= Self.minimumActivity }

    public var verdict: Verdict {
        if duration < Self.minimumDuration { return .tooShort(seconds: duration) }
        return hasSpeech ? .accepted : .silent
    }

    /// Accounts for one buffer of mono samples, in capture order.
    public mutating func observe(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        guard sampleRate > 0 else { return }
        let framesPerWindow = max(1, Int(sampleRate * Self.window))
        duration += Double(samples.count) / sampleRate

        for sample in samples {
            windowEnergy += sample * sample
            windowFrames += 1
            if windowFrames == framesPerWindow {
                let rms = (windowEnergy / Float(windowFrames)).squareRoot()
                if rms >= Self.activityThreshold { activeDuration += Self.window }
                windowEnergy = 0
                windowFrames = 0
            }
        }
    }
}
