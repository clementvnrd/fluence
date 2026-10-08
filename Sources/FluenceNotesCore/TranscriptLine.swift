import Foundation

// FluenceNotesCore is the pure logic behind the Notetaker's notes: chunking, prompt
// assembly, merging, Markdown, retention and the consent notice. It depends on nothing but
// Foundation and works on the plain structs below, so it does not care which module the
// app's `Meeting` lives in, and every rule here runs under `swift test` without a model.

/// One transcript utterance, already attributed to a display name.
public struct TranscriptLine: Sendable, Hashable, Codable {
    /// Seconds from the meeting start.
    public var start: TimeInterval
    /// Display name, e.g. "You", "Marie", "Speaker 2".
    public var speaker: String
    public var text: String

    public init(start: TimeInterval, speaker: String, text: String) {
        self.start = start
        self.speaker = speaker
        self.text = text
    }

    /// The line as the model reads it: `[mm:ss] Name: text`.
    public var rendered: String {
        "[\(Clock.format(start))] \(speaker): \(text)"
    }
}

/// Tape-counter time, the same format as `Meeting.clock`.
public enum Clock {
    public static func format(_ seconds: TimeInterval) -> String {
        let total = Int(shown(seconds).rounded(.down))
        let (h, m, s) = (total / 3600, (total % 3600) / 60, total % 60)
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    /// NaN, the infinities and negatives read as 0, anything past `Int32.max` seconds
    /// (68 years) as that: converting a larger `Double` to `Int` crashes, and a damaged
    /// imported transcript can carry any number (FLU-27).
    static func shown(_ seconds: TimeInterval) -> TimeInterval {
        seconds.isFinite ? min(max(0, seconds), TimeInterval(Int32.max)) : 0
    }
}

/// A meeting length in words, for the list and the export: "45 min", "1 h 05 min".
public enum DurationText {
    public static func format(_ seconds: TimeInterval) -> String {
        let seconds = Clock.shown(seconds)
        let minutes = Int((seconds / 60).rounded())
        if seconds > 0 && minutes == 0 { return "< 1 min" }
        if minutes < 60 { return "\(minutes) min" }
        return String(format: "%d h %02d min", minutes / 60, minutes % 60)
    }
}
