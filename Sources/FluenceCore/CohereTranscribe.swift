import Foundation

/// Cohere Transcribe 03-2026 (2B parameters, Apache-2.0) in MLX 4-bit, an optional dictation
/// engine (FLU-149). On the French bench (`docs/SPEECH-MODELS.md`) it beats Parakeet Ultra on a
/// good microphone and falls well behind it through a webcam mic or in noise; it also writes
/// text on every noise clip. Hence an option for dictation only, never the default, never for
/// meetings — and the guards in `CohereGuard`.
public enum CohereModel {
    /// A file of the pinned checkpoint, with what the download must match.
    public struct File: Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        public let sha256: String
    }

    public static let repo = "lyzgeorge/cohere-transcribe-03-2026-mlx-4bit"
    /// Pinned: the checkpoint the bench measured (`beshkenadze`'s 4-bit build produced garbage).
    public static let revision = "f2f6d89b1a300c51f48ae1ecb8523dbb58636cb0"

    /// What the vendored loader reads (`CohereTranscribeModel.fromDirectory`), nothing more.
    public static let files: [File] = [
        File(name: "config.json", bytes: 4_906,
             sha256: "fe2f7c7b201474b76017c97baa9f1f2d80074de0934d3bcf2fea94007d4af9f4"),
        File(name: "tokenizer_config.json", bytes: 48_138,
             sha256: "b462e16e04c9dbae82289b6ef9b080d8dbad331586ece3ebded0bd09996db636"),
        File(name: "tokenizer.model", bytes: 492_827,
             sha256: "6d21e6a83b2d0d3e1241a7817e4bef8eb63bcb7cfe4a2675af9a35ff3bbf0e14"),
        File(name: "model.safetensors", bytes: 1_507_279_570,
             sha256: "1032930782400476e56d4b852a750920ab49bd048f32eb68aeef5f651077e0a6"),
    ]

    public static var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    public static func url(for file: File) -> URL {
        URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(file.name)")!
    }

    /// Cohere is told the language; it does not detect it. The dictation languages it knows,
    /// nil for Auto and the others (the language's usual engine stands in, `EngineDefault`).
    public static func languageCode(for language: DictationLanguage) -> String? {
        switch language {
        case .english, .french, .german, .spanish, .italian, .portuguese, .dutch, .polish, .greek:
            language.rawValue
        default:
            nil
        }
    }

    /// Every file there at its full size. Sizes from the disk; the SHA-256 is checked once,
    /// when the download ends.
    public static func isComplete(sizes: [String: Int64]) -> Bool {
        files.allSatisfy { sizes[$0.name] == $0.bytes }
    }
}

/// Cohere's guards (FLU-149), each sized on what the bench measured.
public enum CohereGuard {
    /// (a) The decoder's budget for `audioSeconds` of audio. Real speech peaked at 8.2 tokens
    /// a second on the bench; a loop through a webcam mic reached 105. 8/s plus 16 never cut a
    /// real clip there, and stops a loop a few words in.
    public static func maxTokens(audioSeconds: Double) -> Int {
        guard audioSeconds.isFinite, audioSeconds > 0 else { return slackTokens }
        return Int((audioSeconds * tokensPerSecond).rounded(.up)) + slackTokens
    }

    static let tokensPerSecond = 8.0
    static let slackTokens = 16

    /// (b) A phrase said back to back, as a looping decoder does (one 2.8 s webcam clip came
    /// back as the same phrase ten times), is kept once; a cut-off copy at the very end goes
    /// too. Thresholds above people's own repeats: one word 5 times, 2–3 words 4 times, longer
    /// phrases 3 times — so « non non non » and « on y va, on y va, on y va » stay.
    public static func collapseLoops(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let keys = words.map(key)
        var kept: [String] = []
        var i = 0
        scan: while i < words.count {
            for size in stride(from: 1, through: min(maxLoopWords, (words.count - i) / 2), by: 1) {
                let group = keys[i..<(i + size)]
                var end = i + size
                while end + size <= words.count, keys[end..<(end + size)] == group { end += size }
                guard (end - i) / size >= repeatsNeeded(size) else { continue }
                // The budget usually stops a loop mid-copy: a tail that only starts the phrase again.
                let tail = words.count - end
                if tail < size, keys[end...].elementsEqual(group.prefix(tail)) { end = words.count }
                kept += words[i..<(i + size)]
                i = end
                continue scan
            }
            kept.append(words[i])
            i += 1
        }
        return kept.count == words.count ? text : kept.joined(separator: " ")
    }

    static let maxLoopWords = 16

    static func repeatsNeeded(_ size: Int) -> Int {
        switch size {
        case 1: 5
        case 2, 3: 4
        default: 3
        }
    }

    private static func key(_ word: String) -> String {
        TranscriptHealth.normalizedWords(word).joined()
    }

    /// (c) The same gate as every dictation (`SpeechGate`), applied again by the engine itself:
    /// compare mode and a retry hand it a recording without going through the live one.
    public static func hasSpeech(samples: [Float], sampleRate: Double) -> Bool {
        var gate = SpeechGate()
        samples.withUnsafeBufferPointer { gate.observe($0, sampleRate: sampleRate) }
        return gate.verdict == .accepted
    }

    /// (d) Subtitle credits from the model's training data, which it writes over noise
    /// (« Sous-titrage Société Radio-Canada » on 321 of 568 noise clips). Dropped only when
    /// they are the whole output; then (b).
    public static func clean(_ text: String) -> String {
        let words = TranscriptHealth.normalizedWords(text.replacingOccurrences(of: "’", with: "'"))
        if credits.contains(words) || creditPrefixes.contains(where: { words.starts(with: $0) }) { return "" }
        return collapseLoops(text)
    }

    private static let credits: Set<[String]> = [
        ["sous-titrage", "société", "radio-canada"],
        ["merci", "d'avoir", "regardé"],
        ["merci", "d'avoir", "regardé", "cette", "vidéo"],
        ["merci", "d'avoir", "regardé", "la", "vidéo"],
    ]
    private static let creditPrefixes: [[String]] = [["sous-titres", "réalisés", "par"]]
}
