import CryptoKit
import FluenceCore
import FluenceDictionary
import FluenceMeetingCore
import Foundation

// FLU-144: importing a user's dictionary, dictations and meetings from another dictation or
// meeting app on the same Mac. The readers here open the other apps' files read-only and turn
// them into these plain values; `ImportPlanner` decides what is new; the app writes it through
// its own stores. Nothing here writes anywhere, logs or touches the network.

/// The apps Fluence imports from, in the order they are read: an app read later loses its
/// copies of what an earlier one already gave (superwhisper imports Wispr Flow's dictations).
public enum ImportApp: String, CaseIterable, Sendable, Identifiable {
    case wisprFlow, superwhisper, granola

    public var id: String { rawValue }

    public var name: String {
        switch self {
        case .wisprFlow: "Wispr Flow"
        case .superwhisper: "superwhisper"
        case .granola: "Granola"
        }
    }
}

/// One checkbox per app: « Dictionnaire et snippets », « Dictées », « Réunions et notes ».
public enum ImportKind: CaseIterable, Sendable, Hashable {
    case dictionary, dictations, meetings
}

public struct ImportChoice: Hashable, Sendable {
    public var app: ImportApp
    public var kind: ImportKind

    public init(_ app: ImportApp, _ kind: ImportKind) {
        self.app = app
        self.kind = kind
    }
}

/// A dictation as another app kept it: the text the user really got, and when.
public struct ForeignDictation: Sendable, Equatable {
    public var id: UUID
    public var date: Date
    public var text: String
    /// How long the user spoke, when the app says.
    public var seconds: Double

    public init(id: UUID, date: Date, text: String, seconds: Double) {
        self.id = id
        self.date = date
        self.text = text
        self.seconds = seconds
    }
}

/// A meeting, or a note taken outside a meeting (Wispr Flow's « Notes »), as another app kept it.
public struct ForeignMeeting: Sendable {
    public var id: UUID
    public var title: String
    public var startedAt: Date
    public var endedAt: Date?
    public var transcript: ImportedTranscript
    /// What the user wrote.
    public var userNotes: String
    /// The other app's own summary, kept as the meeting's notes.
    public var summary: String?
    public var isNote: Bool

    public init(
        id: UUID, title: String, startedAt: Date, endedAt: Date? = nil,
        transcript: ImportedTranscript = ImportedTranscript(format: .text, turns: []),
        userNotes: String = "", summary: String? = nil, isNote: Bool = false
    ) {
        self.id = id
        self.title = title
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.transcript = transcript
        self.userNotes = userNotes
        self.summary = summary
        self.isNote = isNote
    }
}

/// Everything read from one app.
public struct ForeignData: Sendable {
    public var app: ImportApp
    public var entries: [DictionaryEntry] = []
    public var snippets: [Snippet] = []
    public var dictations: [ForeignDictation] = []
    public var meetings: [ForeignMeeting] = []

    public init(app: ImportApp) {
        self.app = app
    }
}

public enum ImportFailure: Error, Equatable {
    case unreadable
}

/// The same UUID for the same name, every time: what makes a second import add nothing
/// (« wisprflow:dictation:<its id> » is always the same Fluence item).
public enum StableID {
    public static func uuid(_ name: String) -> UUID {
        var b = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x50  // name-based, RFC 4122 layout
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

/// Speaker labels the readers give voices that have no name, cleared once the meeting is
/// built so they read « Intervenant 2 » like a recorded meeting's.
enum Placeholder {
    static let prefix = "\u{1}voice-"
    static let me = prefix + "me"

    static func voice(_ id: String) -> String { prefix + id }
}

enum ForeignDates {
    /// `2026-10-12 14:03:22.123 +00:00` (Wispr Flow), with or without the milliseconds.
    static func wispr(_ text: String) -> Date? {
        for format in ["yyyy-MM-dd HH:mm:ss.SSS xxx", "yyyy-MM-dd HH:mm:ss xxx", "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss"] {
            if let date = formatter(format).date(from: text) { return date }
        }
        return iso(text)
    }

    /// ISO 8601 with or without fractional seconds; without a zone, UTC (superwhisper writes
    /// `2026-10-12T14:03:22` in UTC: measured against Wispr Flow's copies of the same dictations).
    static func iso(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
        return formatter("yyyy-MM-dd'T'HH:mm:ss").date(from: text)
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = format
        return formatter
    }
}

extension String {
    /// Nil when only whitespace.
    var nonBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
