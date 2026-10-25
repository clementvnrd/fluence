import Foundation

/// How long the microphone stays open after the key comes up (FLU-31).
///
/// People let go on the last syllable, not after it, so a fixed 250 ms used to follow every
/// release. On a short phrase that margin was most of the wait. Now the decision is made from
/// the audio itself: if the last `silence` before the release was room tone, the speaker had
/// already finished and the microphone closes as soon as the audio up to the release has
/// arrived; otherwise it stays open for the full `maximum`, as before.
///
/// Times are host-clock seconds (`AVAudioTime.seconds(forHostTime:)`), the clock the capture
/// stamps its buffers with and the release is read on.
public enum PostRoll {
    /// The full post-roll, kept whenever the speaker may still be talking.
    public static let maximum: Double = 0.25
    /// How much room tone before the release proves the last word was over.
    public static let silence: Double = 0.15
    /// How often the controller asks again while the audio up to the release is in flight.
    public static let pollInterval: Double = 0.01

    public enum Decision: Equatable, Sendable {
        /// Keep the microphone open and ask again in `pollInterval`.
        case wait
        /// Close the microphone now.
        case stop(Reason)
    }

    public enum Reason: Equatable, Sendable {
        /// The last `silence` before the release held no sound.
        case trailingSilence
        /// The full `maximum` has passed (sound right up to the release, or no timing).
        case elapsed
    }

    /// - Parameters:
    ///   - trail: what the capture has heard so far.
    ///   - releasedAt: when the key came up.
    ///   - now: the current host time.
    public static func decide(_ trail: TrailingSilence.Snapshot, releasedAt: Double, now: Double) -> Decision {
        if now >= releasedAt + maximum { return .stop(.elapsed) }
        // The audio up to the release has not all arrived yet: nothing can be said about it.
        guard let covered = trail.coveredUntil, covered >= releasedAt else { return .wait }
        guard let lastSound = trail.lastSoundEnd else { return .stop(.trailingSilence) }
        return lastSound <= releasedAt - silence ? .stop(.trailingSilence) : .wait
    }
}

/// Where the last sound ended in the audio captured so far, measured like `SpeechGate`: energy
/// over 20 ms windows against the same threshold, so a window `SpeechGate` would count as
/// sound is never taken for silence here.
///
/// Deliberately conservative. A window counts as sound at about −55 dBFS, well under a quiet
/// final consonant; a noisy room simply never reads as silence and keeps the full post-roll.
/// Only complete windows are judged: the partial one at the end waits for the next buffer.
public struct TrailingSilence: Sendable {
    public struct Snapshot: Equatable, Sendable {
        /// The end of the last complete window, or nil before the first one.
        public var coveredUntil: Double?
        /// The end of the last window that held sound, or nil if none did.
        public var lastSoundEnd: Double?

        public init(coveredUntil: Double? = nil, lastSoundEnd: Double? = nil) {
            self.coveredUntil = coveredUntil
            self.lastSoundEnd = lastSoundEnd
        }
    }

    public static let window: Double = 0.02
    /// A buffer that does not start where the last one ended (a drop, a device change) starts
    /// a new window rather than glueing two stretches of time together. Wider than any
    /// timestamp jitter, narrower than a window.
    static let gapTolerance: Double = 0.01

    public private(set) var snapshot = Snapshot()

    private var windowEnergy: Float = 0
    private var windowFrames = 0
    private var sampleRate: Double = 0
    /// Where the previous buffer ended, to detect gaps.
    private var expectedNext: Double?

    public init() {}

    /// Accounts for one buffer of mono samples.
    /// - Parameter startTime: host time of the buffer's first sample.
    public mutating func observe(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double, startTime: Double) {
        guard sampleRate > 0, startTime.isFinite, !samples.isEmpty else { return }
        if sampleRate != self.sampleRate
            || expectedNext.map({ abs($0 - startTime) > Self.gapTolerance }) ?? true {
            // A fresh stretch. The partial window left over can only add sound, never silence:
            // a sound in it would otherwise be forgotten.
            if windowFrames > 0, let previousEnd = expectedNext,
               (windowEnergy / Float(windowFrames)).squareRoot() >= SpeechGate.activityThreshold {
                snapshot.lastSoundEnd = previousEnd
            }
            self.sampleRate = sampleRate
            windowEnergy = 0
            windowFrames = 0
        }
        let framesPerWindow = max(1, Int(sampleRate * Self.window))
        var index = 0
        for sample in samples {
            windowEnergy += sample * sample
            windowFrames += 1
            index += 1
            if windowFrames == framesPerWindow {
                let end = startTime + Double(index) / sampleRate
                let rms = (windowEnergy / Float(windowFrames)).squareRoot()
                if rms >= SpeechGate.activityThreshold { snapshot.lastSoundEnd = end }
                snapshot.coveredUntil = end
                windowEnergy = 0
                windowFrames = 0
            }
        }
        expectedNext = startTime + Double(samples.count) / sampleRate
    }

    public mutating func observe(_ samples: [Float], sampleRate: Double, startTime: Double) {
        samples.withUnsafeBufferPointer { observe($0, sampleRate: sampleRate, startTime: startTime) }
    }
}
