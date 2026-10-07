import Foundation

/// What the level bars show (FLU-23): the loudness of what the microphone actually hears,
/// so silence draws flat bars and speech raises them. Shared by the dictation meters and the
/// meeting surfaces.
public enum AudioLevel {
    /// Below this, a quiet room: nothing to show. Fan and room noise sit around -60…-50 dBFS.
    public static let floor: Float = -52
    /// Normal speech close to the mic peaks around here: full bars.
    public static let ceiling: Float = -12

    public static func rms(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for sample in samples { sum += sample * sample }
        return (sum / Float(samples.count)).squareRoot()
    }

    public static func rms(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { rms($0) }
    }

    public static func dbfs(rms: Float) -> Float {
        20 * log10(max(rms, 1e-7))
    }

    /// 0 at or below `floor`, 1 at or above `ceiling`, linear in dB between.
    public static func normalized(dbfs: Float, floor: Float = floor, ceiling: Float = ceiling) -> Float {
        max(0, min(1, (dbfs - floor) / (ceiling - floor)))
    }

    /// The 0…1 level of one buffer.
    public static func level(_ samples: UnsafeBufferPointer<Float>) -> Float {
        normalized(dbfs: dbfs(rms: rms(samples)))
    }

    public static func level(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { level($0) }
    }
}

/// Smooths the level like a meter: rises quickly when you speak, falls back more slowly so
/// the bars don't strobe between words. Time-based, so the result does not depend on the
/// buffer size or the sample rate.
public struct LevelFollower: Sendable {
    public var attack: TimeInterval
    public var release: TimeInterval
    public private(set) var value: Float = 0

    public init(attack: TimeInterval = 0.05, release: TimeInterval = 0.3) {
        self.attack = attack
        self.release = release
    }

    /// Moves toward `target` over `dt` seconds and returns the new value.
    @discardableResult
    public mutating func update(target: Float, dt: TimeInterval) -> Float {
        guard dt > 0 else { return value }
        let tau = target > value ? attack : release
        let coefficient = Float(1 - exp(-dt / tau))
        value += (target - value) * coefficient
        if value < 0.005 { value = 0 }  // invisible on the bars; lets silence read as 0
        return value
    }

    public mutating func reset() {
        value = 0
    }
}
