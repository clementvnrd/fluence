import Foundation
import NaturalLanguage

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

    /// Up to this many words, a segment that is neither French nor English is dropped.
    public static let foreignWords = 3
    static let minimumForeign = 0.95
    static let maximumFrenchEnglish = 0.01
    /// French, English and the other Parakeet v3 languages NaturalLanguage knows.
    static let languages: [NLLanguage] = [
        .french, .english, .dutch, .swedish, .german, .spanish, .italian, .portuguese, .polish, .danish,
        .norwegian, .finnish, .czech, .romanian, .hungarian, .slovak, .croatian, .greek, .bulgarian, .russian, .ukrainian,
    ]

    /// FLU-147: Parakeet writes short French it half-heard on the call as Swedish, Dutch, German…
    /// (« Här. », « Waar het moet? »). A segment of up to three words is foreign when the on-device
    /// recognizer is sure (≥ 0.95) of another language and gives French + English < 1 %. English
    /// stays (franglais), so do numbers and symbols. Measured: 24 of 46 real foreign outputs
    /// dropped, 0 of 837 short French/English answers and fragments; « Non. » is Italian at 0.94.
    public static func isForeign(_ text: String) -> Bool {
        guard TextTokens.normalize(text).count <= foreignWords,
              text.filter(\.isNumber).count < text.filter(\.isLetter).count else { return false }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages
        recognizer.processString(text)
        let hypotheses = recognizer.languageHypotheses(withMaximum: languages.count)
        guard let top = hypotheses.max(by: { $0.value < $1.value }), top.key != .french, top.key != .english else { return false }
        return top.value >= minimumForeign && (hypotheses[.french] ?? 0) + (hypotheses[.english] ?? 0) < maximumFrenchEnglish
    }

    /// The probabilities of every hop that `[start, end)` overlaps, clamped to those analysed.
    public static func hops(_ probabilities: [Float], from start: Int, to end: Int, hop: Int) -> ArraySlice<Float> {
        guard !probabilities.isEmpty else { return [] }
        let first = min(max(start, 0) / hop, probabilities.count - 1)
        let last = min(max(first + 1, (end + hop - 1) / hop), probabilities.count)
        return probabilities[first..<last]
    }
}
