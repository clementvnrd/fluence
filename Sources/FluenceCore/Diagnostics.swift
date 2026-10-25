import Foundation

// MARK: - Events

/// One error or recovery the app went through, as the diagnostic export lists it (FLU-35).
///
/// It carries no text by construction: `kind` is a fixed identifier written in the code
/// ("history.write"), never a message, and every string is checked against
/// `DiagnosticToken` on the way in — on creation and again when read back from disk. Repeats
/// of the same event in a row are folded into one entry with a count, so a fault that fires
/// on every audio buffer cannot push everything else out of the ring.
public struct DiagnosticEvent: Codable, Sendable, Equatable {
    public enum Severity: String, Codable, Sendable {
        /// Something failed (a write, an engine, a permission).
        case error
        /// Something failed and the app got back on its feet on its own (an event tap re-armed,
        /// an interrupted meeting recovered, a fallback taken).
        case recovery
    }

    public let kind: String
    public let severity: Severity
    /// `NSError.code` or an `OSStatus`, when there is one.
    public let code: Int?
    /// `NSError.domain`, when there is one.
    public let domain: String?
    public private(set) var first: Date
    public private(set) var last: Date
    public private(set) var count: Int

    /// Nil when `kind` is not a plain identifier. A domain that is not one is dropped.
    public init?(kind: String, severity: Severity, code: Int? = nil, domain: String? = nil, at date: Date) {
        guard let kind = DiagnosticToken.identifier(kind) else { return nil }
        self.kind = kind
        self.severity = severity
        self.code = code
        self.domain = domain.flatMap(DiagnosticToken.identifier)
        first = date
        last = date
        count = 1
    }

    /// Same event as `other`, regardless of when and how often.
    func isRepeat(of other: DiagnosticEvent) -> Bool {
        kind == other.kind && severity == other.severity && code == other.code && domain == other.domain
    }

    mutating func repeated(at date: Date) {
        last = max(last, date)
        count += 1
    }

    private enum CodingKeys: String, CodingKey { case kind, severity, code, domain, first, last, count }

    /// What comes back from disk goes through the same checks as what is recorded: a file
    /// edited by hand, or written by a later version, cannot smuggle text into the export.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let kind = DiagnosticToken.identifier(try container.decode(String.self, forKey: .kind)) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "not an identifier")
        }
        self.kind = kind
        severity = try container.decode(Severity.self, forKey: .severity)
        code = try container.decodeIfPresent(Int.self, forKey: .code)
        domain = try container.decodeIfPresent(String.self, forKey: .domain).flatMap(DiagnosticToken.identifier)
        first = try container.decode(Date.self, forKey: .first)
        last = try container.decode(Date.self, forKey: .last)
        count = max(1, try container.decode(Int.self, forKey: .count))
    }
}

/// The last `capacity` events, oldest first. Pure: the app seals and stores it.
public struct DiagnosticRing: Codable, Sendable, Equatable {
    /// The issue asks for the last 200 error kinds in the export.
    public static let capacity = 200

    public private(set) var events: [DiagnosticEvent] = []

    public init(events: [DiagnosticEvent] = []) {
        self.events = Array(events.suffix(Self.capacity))
    }

    public mutating func record(_ event: DiagnosticEvent) {
        if let lastIndex = events.indices.last, events[lastIndex].isRepeat(of: event) {
            events[lastIndex].repeated(at: event.last)
            return
        }
        events.append(event)
        if events.count > Self.capacity {
            events.removeFirst(events.count - Self.capacity)
        }
    }

    /// The file format: JSON, ISO 8601 dates. Sealed by the app before it touches the disk.
    public func encoded() throws -> Data {
        try Self.encoder.encode(self)
    }

    /// Unreadable entries are dropped one by one rather than costing the whole ring.
    public static func decoded(_ data: Data) -> DiagnosticRing? {
        struct Lenient: Decodable {
            var events: [DiagnosticEvent]
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                var list = try container.nestedUnkeyedContainer(forKey: .events)
                var events: [DiagnosticEvent] = []
                while !list.isAtEnd {
                    if let event = try? list.decode(DiagnosticEvent.self) {
                        events.append(event)
                    } else if (try? list.decode(Skip.self)) == nil {
                        break
                    }
                }
                self.events = events
            }
            private enum CodingKeys: String, CodingKey { case events }
            /// Reads nothing and always succeeds, which moves the list past a bad entry.
            private struct Skip: Decodable {
                init(from decoder: any Decoder) throws {}
            }
        }
        guard let lenient = try? decoder.decode(Lenient.self, from: data) else { return nil }
        return DiagnosticRing(events: lenient.events)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

// MARK: - Tokens

/// The only strings a diagnostic may contain besides numbers and dates: short identifiers
/// and values from the app's own vocabulary. Anything else — a sentence, a path, a name with
/// an accent or a space — is refused, not cleaned up.
public enum DiagnosticToken {
    /// `history.write`, `NSCocoaErrorDomain`, `openai_whisper-small`: ASCII letters, digits,
    /// `.`, `_`, `-`, 1 to 80 characters.
    public static func identifier(_ raw: String) -> String? {
        guard (1...80).contains(raw.utf8.count), raw.unicodeScalars.allSatisfy(isIdentifierScalar) else { return nil }
        return raw
    }

    /// A value such as an engine name ("Apple (streaming)") or an OS version
    /// ("Version 26.1 (Build 25B78)"): an identifier that may also hold spaces, parentheses,
    /// `,`, `:` and `+`. Still ASCII only, 1 to 80 characters.
    public static func value(_ raw: String) -> String? {
        guard (1...80).contains(raw.utf8.count),
              raw.unicodeScalars.allSatisfy({ isIdentifierScalar($0) || " (),:+".unicodeScalars.contains($0) })
        else { return nil }
        return raw
    }

    private static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a"..."z", "A"..."Z", "0"..."9", ".", "_", "-": true
        default: false
        }
    }
}

// MARK: - Crash reports

public enum CrashReportName {
    /// The name a macOS crash, hang or resource report of Fluence is listed under in the
    /// export, rebuilt from its date and type only: `Fluence-2026-10-08-101500.ips`.
    ///
    /// The file names macOS writes can carry the Mac's name (`…_MacBook-de-Clement.diag`),
    /// which is often the owner's name, so the original name is never copied. Nil for
    /// another process's report.
    public static func listed(_ fileName: String) -> String? {
        let pattern = #"^Fluence[-_.](?:.*?[-_.])?(\d{4}-\d{2}-\d{2}-\d{6})(?:[-_.].*)?\.(ips|crash|diag|hang|spin)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: fileName, range: NSRange(fileName.startIndex..., in: fileName)),
              let stamp = Range(match.range(at: 1), in: fileName),
              let type = Range(match.range(at: 2), in: fileName)
        else { return nil }
        return "Fluence-\(fileName[stamp]).\(fileName[type])"
    }
}

// MARK: - Report

/// The diagnostic file Clement can send when something goes wrong (FLU-35): versions,
/// settings, counts and timings, the last errors, the names of Fluence's crash reports.
///
/// Built only from what is in `Input`, and every string in `Input` goes through
/// `DiagnosticToken` here, so no caller can put dictated text, a meeting, a name or a path in
/// it by mistake: a value that is not a token prints as `(masqué)`. On top of that, the
/// strings in `redact` (the home folder, the account and Mac names) are replaced wherever
/// they would still appear.
public struct DiagnosticReport: Sendable {
    public struct Input: Sendable {
        public var generatedAt: Date
        /// Version, build, bundle ID, OS, hardware model, build flags.
        public var app: [(String, String)]
        /// Setting name → value, from the app's own vocabulary (enum raw values, numbers).
        public var settings: [(String, String)]
        public var counts: [(String, Int)]
        /// Seconds.
        public var timings: [(String, Double)]
        public var events: [DiagnosticEvent]
        /// Raw file names; only Fluence's are listed, rebuilt by `CrashReportName`.
        public var crashReportFiles: [String]
        /// Strings that must never appear in the file, whatever happens.
        public var redact: [String]

        public init(
            generatedAt: Date,
            app: [(String, String)] = [],
            settings: [(String, String)] = [],
            counts: [(String, Int)] = [],
            timings: [(String, Double)] = [],
            events: [DiagnosticEvent] = [],
            crashReportFiles: [String] = [],
            redact: [String] = []
        ) {
            self.generatedAt = generatedAt
            self.app = app
            self.settings = settings
            self.counts = counts
            self.timings = timings
            self.events = events
            self.crashReportFiles = crashReportFiles
            self.redact = redact
        }
    }

    static let masked = "(masqué)"

    public static func render(_ input: Input) -> String {
        var lines: [String] = []
        lines.append("Fluence — diagnostic")
        lines.append("Aucun texte dicté, aucune réunion, aucun nom. Rien n'a été envoyé.")
        lines.append("generated: \(timestamp(input.generatedAt))")

        lines.append("")
        lines.append("[app]")
        for (key, value) in input.app { lines.append(pair(key, DiagnosticToken.value(value))) }

        lines.append("")
        lines.append("[settings]")
        for (key, value) in input.settings { lines.append(pair(key, DiagnosticToken.value(value))) }

        lines.append("")
        lines.append("[counts]")
        for (key, value) in input.counts { lines.append(pair(key, String(value))) }

        lines.append("")
        lines.append("[timings]")
        for (key, seconds) in input.timings {
            lines.append(pair(key, seconds.isFinite ? String(format: "%.3f s", seconds) : nil))
        }

        let events = input.events.suffix(DiagnosticRing.capacity)
        lines.append("")
        lines.append("[events] \(events.count), oldest first")
        for event in events {
            var line = "\(timestamp(event.last)) \(event.severity.rawValue) \(event.kind)"
            if let domain = event.domain { line += " domain=\(domain)" }
            if let code = event.code { line += " code=\(code)" }
            if event.count > 1 { line += " ×\(event.count) since \(timestamp(event.first))" }
            lines.append(line)
        }

        let crashes = Array(Set(input.crashReportFiles.compactMap(CrashReportName.listed))).sorted()
        lines.append("")
        lines.append("[crash reports] \(crashes.count)")
        lines.append(contentsOf: crashes)

        var text = lines.joined(separator: "\n") + "\n"
        // Longest first, so a home folder is replaced whole before the account name inside it.
        for secret in input.redact.filter({ $0.count >= 3 }).sorted(by: { $0.count > $1.count }) {
            text = text.replacingOccurrences(of: secret, with: "•••", options: [.caseInsensitive, .diacriticInsensitive])
        }
        return text
    }

    private static func pair(_ key: String, _ value: String?) -> String {
        "\(DiagnosticToken.identifier(key) ?? masked): \(value ?? masked)"
    }

    private static func timestamp(_ date: Date) -> String {
        date.formatted(.iso8601)
    }
}

// MARK: - Timings

public enum DiagnosticStats {
    /// The value below which `fraction` of `values` fall (nearest rank). Nil when empty.
    public static func percentile(_ values: [Double], _ fraction: Double) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[min(max(rank, 1), sorted.count) - 1]
    }
}
