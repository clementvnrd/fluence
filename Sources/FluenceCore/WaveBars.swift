import Foundation

/// The heights of the small level waveform (`MiniWave`): as tall as the input is loud (FLU-23),
/// with a light ripple while there is sound.
///
/// With *Reduce Motion* (FLU-38) there is no ripple: the bars follow the voice only, so nothing
/// moves on its own and silence is still.
public enum WaveBars {
    /// The height of a bar at rest.
    public static let floor = 3.5

    /// - Parameters:
    ///   - level: the input level, 0…1 (`AudioLevel`); `nil` when the caller has none, and the
    ///     bars then just show activity.
    ///   - time: seconds, any origin; drives the ripple.
    public static func height(
        index: Int,
        count: Int,
        level: Double?,
        isActive: Bool,
        time: Double,
        maxHeight: Double,
        reduceMotion: Bool
    ) -> Double {
        guard isActive else { return floor }
        let phase = (Double(index) * 0.618).truncatingRemainder(dividingBy: 1)
        let wave = reduceMotion ? 0 : sin(time * 6.5 + phase * .pi * 2)
        guard let level else {
            return floor + 0.6 * (0.6 + 0.4 * wave) * (maxHeight - floor)
        }
        // Taller in the middle, like a voice; the ripple scales with the level, so silence is
        // perfectly still.
        let position = count > 1 ? Double(index) / Double(count - 1) : 0.5
        let shape = 1 - abs(position - 0.5) * 0.9
        let amount = level * shape * (0.85 + 0.15 * wave)
        return min(maxHeight, floor + max(0, amount) * (maxHeight - floor))
    }
}
