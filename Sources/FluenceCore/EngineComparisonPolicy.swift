import Foundation

// Compare mode's decisions (FLU-48): which engines a comparison runs, when it waits for an
// outside app's result, and how a finished comparison is ranked and labelled. Pure, so the
// rules are tested here; the app only runs the engines and draws the rows.

/// An on-device engine compare mode can run.
public enum ComparedEngine: String, CaseIterable, Sendable {
    case apple
    case parakeet
    case whisper

    /// The row title. Short on purpose: the comparison card has little room.
    public var displayName: String {
        switch self {
        case .apple: "Apple"
        case .parakeet: "Parakeet"
        case .whisper: "Whisper"
        }
    }
}

public enum ComparisonPlan {
    /// The engines a comparison runs, in the order they run.
    ///
    /// Apple always: its speech model comes with macOS. Parakeet and Whisper only when their
    /// model is already on disk. A comparison never downloads one: Parakeet's first load is
    /// ~600 MB, Whisper's up to 1.5 GB, and a recording is not the moment to start that
    /// unasked. The comparison window offers the download as an explicit button instead.
    public static func engines(parakeetOnDisk: Bool, whisperOnDisk: Bool) -> [ComparedEngine] {
        var engines: [ComparedEngine] = [.apple]
        if parakeetOnDisk { engines.append(.parakeet) }
        if whisperOnDisk { engines.append(.whisper) }
        return engines
    }

    /// Whether the comparison waits for an outside dictation app's result.
    ///
    /// Only when Fluence itself pressed that app's key for this recording: without the key,
    /// the app heard nothing and there is no result to wait for. A comparison started with
    /// Fluence's own shortcut therefore ends as soon as the local engines do.
    public static func waitsForExternalResult(installed: Bool, keyPressedByFluence: Bool) -> Bool {
        installed && keyPressedByFluence
    }

    /// Where the outside app's stamp for this recording may fall.
    ///
    /// The app stamps its row with the moment its own utterance began, which is close to, and
    /// often just before, our hold start: hence `slack` on both sides. Two bounds keep a
    /// neighbouring recording's row out, now that a new dictation may start while the previous
    /// comparison still waits: never past this recording's release (nothing it heard began
    /// later), never before the previous recording's release.
    public static func externalStampWindow(
        holdStarted: Date,
        releasedAt: Date,
        previousReleasedAt: Date?,
        slack: TimeInterval = 5
    ) -> ClosedRange<Date> {
        var lower = holdStarted.addingTimeInterval(-slack)
        if let previousReleasedAt, previousReleasedAt > lower, previousReleasedAt <= holdStarted {
            lower = previousReleasedAt
        }
        // A release a hair after the press would make a window too narrow to catch an app that
        // reacts to its key a moment late; the hold-start side keeps at least a second.
        let upper = min(holdStarted.addingTimeInterval(slack), max(releasedAt, holdStarted.addingTimeInterval(1)))
        return lower...max(lower, upper)
    }
}

/// One engine's result for a compared recording, as the comparison card reads it.
public struct ComparisonRow: Sendable, Equatable {
    /// What the time measures, which decides whether rows can be ranked together.
    public enum Timing: Sendable, Equatable {
        /// Local compute, the clock started after the model loaded.
        case compute
        /// An outside app's own end-to-end latency: network round trip and cleanup included.
        case endToEnd
    }

    public enum Status: Sendable, Equatable {
        case transcribed
        case heardNothing
        case failed
    }

    /// Shown for a failed row whose stored message cannot be shown as is (older rows kept the
    /// engine's own English error text).
    public static let genericFailure = "La transcription a échoué."
    /// An engine that could not even start (its model failed to load, say).
    public static let startFailure = "Le moteur n'a pas pu démarrer."

    public let engine: String
    public let seconds: Double
    public let audioSeconds: Double
    public let text: String
    public let timing: Timing
    public let status: Status

    /// - Parameter failed: nil for rows saved before the flag existed; those marked a failure
    ///   with a "⚠️" text, which is read back as one.
    public init(engine: String, seconds: Double, audioSeconds: Double, text: String, failed: Bool?, timing: Timing) {
        self.engine = engine
        self.seconds = seconds
        self.audioSeconds = audioSeconds
        self.text = text
        self.timing = timing
        let isFailure = failed ?? text.hasPrefix("⚠️")
        if isFailure {
            status = .failed
        } else if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            status = .heardNothing
        } else {
            status = .transcribed
        }
    }

    /// Audio length over compute time. Nil when that would say nothing true: a failed engine
    /// (its zero seconds once read as tens of thousands × real time), no measured time, or an
    /// end-to-end latency, which is mostly network.
    public var realtimeFactor: Double? {
        guard status != .failed, timing == .compute, seconds > 0, seconds.isFinite,
              audioSeconds > 0, audioSeconds.isFinite
        else { return nil }
        return audioSeconds / seconds
    }

    /// The small line under the engine name.
    public var speedLabel: String {
        if status == .failed { return "échec" }
        if timing == .endToEnd { return "réseau compris" }
        guard let factor = realtimeFactor else { return "" }
        return "\(Int(factor.rounded()))×\(FrenchFormat.space)temps réel"
    }

    /// The row's text, in French when the engine failed.
    public var displayText: String {
        switch status {
        case .transcribed: text
        case .heardNothing: "(rien de reconnu)"
        case .failed:
            text.isEmpty || text.hasPrefix("⚠️") ? Self.genericFailure : text
        }
    }
}

/// A comparison's rows put in order.
///
/// Local engines are ranked by compute time, fastest first. An end-to-end latency (Wispr
/// Flow's, network included) is never put in that ranking: it is listed apart.
public struct ComparisonRanking: Sendable, Equatable {
    public enum Margin: Sendable, Equatable {
        case tied
        case ahead(engine: String, ratio: Double, seconds: Double)
    }

    public enum Verdict: String, Sendable, Equatable {
        case identical = "identique"
        case sameWords = "mêmes mots"
        case differentWords = "mots différents"
    }

    /// Local rows: those that transcribed something, fastest first; then those that heard
    /// nothing; failed ones last. Within a group, the time decides.
    public let local: [ComparisonRow]
    /// End-to-end rows, apart, in arrival order.
    public let endToEnd: [ComparisonRow]

    public init(_ rows: [ComparisonRow]) {
        func order(_ status: ComparisonRow.Status) -> Int {
            switch status {
            case .transcribed: 0
            case .heardNothing: 1
            case .failed: 2
            }
        }
        local = rows.filter { $0.timing == .compute }.enumerated().sorted { a, b in
            let (oa, ob) = (order(a.element.status), order(b.element.status))
            if oa != ob { return oa < ob }
            if a.element.seconds != b.element.seconds { return a.element.seconds < b.element.seconds }
            return a.offset < b.offset
        }.map(\.element)
        endToEnd = rows.filter { $0.timing == .endToEnd }
    }

    /// Local rows that took part in the race: a failure, or an engine that heard nothing,
    /// did not win anything by being quick.
    private var contenders: [ComparisonRow] { local.filter { $0.status == .transcribed } }

    /// The fastest local engine, once at least two have transcribed something.
    public var winner: ComparisonRow? {
        contenders.count >= 2 ? contenders.first : nil
    }

    /// How far ahead the winner finished, against the slowest local engine that transcribed.
    public var margin: Margin? {
        let contenders = self.contenders
        guard contenders.count >= 2, let best = contenders.first, let slowest = contenders.last,
              best.seconds > 0
        else { return nil }
        let delta = slowest.seconds - best.seconds
        guard delta > 0.005 else { return .tied }
        return .ahead(engine: best.engine, ratio: slowest.seconds / best.seconds, seconds: delta)
    }

    public var marginLabel: String? {
        switch margin {
        case nil: nil
        case .tied: "à égalité"
        case .ahead(let engine, let ratio, let seconds):
            "\(engine) : " + String(format: "%.1f", ratio).replacingOccurrences(of: ".", with: ",")
                + "× plus rapide · \(FrenchFormat.seconds(seconds)) d'avance"
        }
    }

    /// Whether the engines heard the same thing, over every row that did not fail (the
    /// end-to-end ones included: words are words, whatever the clock). Letter case and
    /// punctuation are left out: Apple punctuates and Parakeet does not, which is formatting
    /// rather than a word heard wrong. Nil under two such rows.
    public var verdict: Verdict? {
        let texts = (local + endToEnd).filter { $0.status != .failed }.map(\.text)
        guard texts.count >= 2 else { return nil }
        if Set(texts).count == 1 { return .identical }
        let normalized = Set(texts.map { text in
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        })
        return normalized.count == 1 ? .sameWords : .differentWords
    }
}

extension FrenchFormat {
    /// "Apple", "Apple et Parakeet", "Apple, Parakeet et Whisper".
    public static func list(_ items: [String]) -> String {
        guard let last = items.last else { return "" }
        guard items.count > 1 else { return last }
        return items.dropLast().joined(separator: ", ") + " et " + last
    }
}
