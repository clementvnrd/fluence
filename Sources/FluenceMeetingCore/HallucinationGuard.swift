import Foundation

/// FLU-147: whether a transcribed meeting utterance was speech, from what Silero heard over it.
///
/// Parakeet answers « Yeah », « Okay », « Mm-hmm », « No » to a sip, a cough, a sneeze or a
/// click that the VAD let through (0.5 to start, 0.35 to go on). Real speech, however short,
/// has a hop near 1 and a mean well above the gate; those sounds hover around it. Measured on
/// ESC-50 sounds vs real short French answers and FLEURS fragments through the same VAD,
/// segmenter and Parakeet call (docs/SPEECH-MODELS.md, « Meetings »): 32 of 55 sounds
/// dropped, 0 of 55 correctly transcribed short answers, 14 of 1 080 real segments (1.3 %,
/// most of them already mis-transcribed). Token confidence, length and RMS did not separate
/// them better, so they are not used.
public enum HallucinationGuard {
    /// Up to this many words a segment needs the VAD's evidence; longer ones are kept.
    public static let shortWords = 2
    public static let minimumMean: Float = 0.45
    public static let minimumPeak: Float = 0.9

    /// `vad`: the hop probabilities over the utterance (`hops`); empty when there are none
    /// (the energy fallback, a later launch), and then the segment is kept.
    public static func keeps(text: String, vad: [Float]) -> Bool {
        guard !vad.isEmpty, TextTokens.normalize(text).count <= shortWords else { return true }
        let mean = vad.reduce(0, +) / Float(vad.count)
        return mean >= minimumMean && (vad.max() ?? 0) >= minimumPeak
    }

    /// The probabilities of every hop that `[start, end)` overlaps, clamped to those analysed.
    public static func hops(_ probabilities: [Float], from start: Int, to end: Int, hop: Int) -> ArraySlice<Float> {
        guard !probabilities.isEmpty else { return [] }
        let first = min(max(start, 0) / hop, probabilities.count - 1)
        let last = min(max(first + 1, (end + hop - 1) / hop), probabilities.count)
        return probabilities[first..<last]
    }
}
