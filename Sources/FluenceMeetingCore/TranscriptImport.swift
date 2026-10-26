import Foundation

/// A meeting transcript written by another tool or by hand, read into speaker turns so it
/// can join the meetings library (FLU-16).
///
/// Three shapes are read:
/// - **WebVTT** (`.vtt`, Zoom and Teams exports): cues with times; the speaker is a
///   `<v Name>` voice span (Teams) or a `Name: ` prefix (Zoom). Consecutive cues of one
///   speaker are joined into one turn.
/// - **SubRip** (`.srt`): the same cues, with comma decimals.
/// - **Text and Markdown**: `Name: text` lines, optionally with a `[mm:ss]` time before the
///   line or after the name (Fluence's own export is `[mm:ss] Name: text`). A line holding
///   only a name and a time (Otter) or only a time (Google Meet) starts the next turn; lines
///   without a name continue the current turn; a blank line ends it; `# Title` names the
///   meeting.
///
/// The contract is `Tests/FluenceMeetingCoreTests/transcript-import-vectors.json`.
public struct ImportedTranscript: Sendable, Equatable {
    public enum Format: String, Sendable, Codable {
        case webVTT = "vtt"
        case subRip = "srt"
        case text
    }

    public struct Turn: Sendable, Equatable {
        public var speaker: String?
        /// Seconds from the start of the meeting, when the file says.
        public var start: TimeInterval?
        public var end: TimeInterval?
        public var text: String

        public init(speaker: String?, start: TimeInterval? = nil, end: TimeInterval? = nil, text: String) {
            self.speaker = speaker
            self.start = start
            self.end = end
            self.text = text
        }
    }

    public var format: Format
    /// The first `# heading` of a Markdown file, when it comes before any turn.
    public var title: String?
    public var turns: [Turn]

    public init(format: Format, title: String? = nil, turns: [Turn]) {
        self.format = format
        self.title = title
        self.turns = turns
    }

    /// Speaker names in order of first appearance.
    public var speakers: [String] {
        var seen: [String] = []
        for case let name? in turns.map(\.speaker) where !seen.contains(name) {
            seen.append(name)
        }
        return seen
    }

    /// Whether every turn carries its time, so the meeting's length is known rather than
    /// estimated.
    public var isTimed: Bool {
        !turns.isEmpty && turns.allSatisfy { $0.start != nil }
    }
}

public enum TranscriptImport {
    /// Consecutive cues of one speaker are joined while the pause between them is at most
    /// this long…
    static let cueJoinGap: TimeInterval = 2
    /// …and the joined turn stays this short, so a monologue still reads in paragraphs.
    static let cueJoinLimit: TimeInterval = 60
    /// Speaking rate for untimed text: 150 words a minute.
    static let secondsPerWord: TimeInterval = 0.4

    // MARK: - Reading

    public static func parse(_ raw: String) -> ImportedTranscript {
        let text = raw
            .replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let lines = text.components(separatedBy: "\n")
        let first = lines.lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        if first.hasPrefix("WEBVTT") {
            return ImportedTranscript(format: .webVTT, turns: joined(unified(readCues(lines))))
        }
        if lines.contains(where: { cueTiming($0) != nil }) {
            return ImportedTranscript(format: .subRip, turns: joined(unified(readCues(lines))))
        }
        var transcript = readText(lines)
        transcript.turns = unified(transcript.turns)
        return transcript
    }

    /// One speaker per person, however the file spells them (FLU-22): "Clément", "Clement"
    /// and "CLÉMENT" are one voice, named the way the file first wrote it with a capital.
    static func unified(_ turns: [ImportedTranscript.Turn]) -> [ImportedTranscript.Turn] {
        func key(_ name: String) -> String {
            name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }
        var names: [String: String] = [:]
        for case let speaker? in turns.map(\.speaker) {
            let k = key(speaker)
            if let chosen = names[k], chosen.first?.isUppercase == true || speaker.first?.isUppercase != true { continue }
            names[k] = speaker
        }
        return turns.map { turn in
            var copy = turn
            copy.speaker = turn.speaker.map { names[key($0)] ?? $0 }
            return copy
        }
    }

    /// Words that head a section of notes rather than name a person (FLU-22: a "Workflow:"
    /// line became a speaker). Compared without case or accents.
    static let sectionLabels: Set<String> = [
        "workflow", "agenda", "ordre du jour", "note", "notes", "remarque", "remarques",
        "action", "actions", "action items", "action item", "to do", "todo", "a faire",
        "next steps", "prochaines etapes", "prochaine etape", "etapes", "decision", "decisions",
        "question", "questions", "q", "r", "a", "summary", "resume", "recap", "recapitulatif",
        "conclusion", "conclusions", "contexte", "context", "objectif", "objectifs", "goal", "goals",
        "points", "points cles", "key points", "point", "sujet", "sujets", "topic", "topics",
        "important", "attention", "exemple", "example", "update", "updates", "status", "statut",
        "participants", "attendees", "presents", "date", "heure", "time", "lieu", "location",
        "duree", "duration", "titre", "title", "transcript", "transcription", "compte rendu",
        "minutes", "intro", "introduction", "highlights", "risques", "risks", "blockers", "bloquants",
    ]

    static func isSectionLabel(_ name: String) -> Bool {
        let key = name
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return sectionLabels.contains(key)
    }

    /// Cues are blocks separated by blank lines: an optional identifier, a timing line,
    /// then the payload. Blocks without a timing line (the header, `NOTE`, `STYLE`) are
    /// skipped.
    private static func readCues(_ lines: [String]) -> [ImportedTranscript.Turn] {
        var turns: [ImportedTranscript.Turn] = []
        var block: [String] = []

        func flush() {
            defer { block.removeAll() }
            guard let timingIndex = block.firstIndex(where: { cueTiming($0) != nil }),
                  let timing = cueTiming(block[timingIndex])
            else { return }
            let payload = block[(timingIndex + 1)...].joined(separator: " ")
            var speaker = payload.firstMatch(of: #/<v(?:\.[^\s>]*)?\s+([^>]+)>/#)
                .map { collapse(String($0.1)) }
            var body = collapse(decodeEntities(payload.replacing(#/<[^>]*>/#, with: "")))
            if speaker == nil, let prefix = speakerPrefix(body, strict: false) {
                speaker = prefix.name
                body = prefix.rest
            }
            guard !body.isEmpty else { return }
            turns.append(.init(speaker: speaker, start: timing.start, end: timing.end, text: body))
        }

        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                flush()
            } else {
                block.append(line)
            }
        }
        flush()
        return turns
    }

    /// Joins consecutive cues of one speaker separated by a short pause.
    private static func joined(_ cues: [ImportedTranscript.Turn]) -> [ImportedTranscript.Turn] {
        var turns: [ImportedTranscript.Turn] = []
        for cue in cues {
            if var last = turns.last, last.speaker == cue.speaker,
               let lastStart = last.start, let lastEnd = last.end,
               let start = cue.start, let end = cue.end,
               start - lastEnd <= cueJoinGap, end - lastStart <= cueJoinLimit {
                last.text += " " + cue.text
                last.end = end
                turns[turns.count - 1] = last
            } else {
                turns.append(cue)
            }
        }
        return turns
    }

    private static func readText(_ lines: [String]) -> ImportedTranscript {
        var title: String?
        var turns: [ImportedTranscript.Turn] = []
        var speaker: String?
        var pendingTime: TimeInterval?
        /// The next text line starts a new turn rather than continuing the last one.
        var breakBefore = true

        for raw in lines {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                breakBefore = true
                continue
            }
            if let heading = line.firstMatch(of: #/^(#{1,6})\s+(.*)$/#) {
                if heading.1.count == 1, title == nil, turns.isEmpty {
                    title = collapse(String(heading.2).replacingOccurrences(of: "**", with: ""))
                }
                breakBefore = true
                continue
            }
            if line.allSatisfy({ "-*_=".contains($0) }) { continue }  // a rule: --- *** ___

            line = String(line.replacing(#/^(?:[-*+>]\s+)+/#, with: ""))
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")

            var time: TimeInterval?
            if let match = line.firstMatch(of: #/^[\[(]?((?:\d+:)?\d{1,2}:\d{2})(?:[.,]\d+)?[\])]?(?:\s*[-–—|]\s*|\s+|$)(.*)$/#) {
                time = seconds(String(match.1))
                line = String(match.2).trimmingCharacters(in: .whitespaces)
            }
            if line.isEmpty {
                // A time on its own line: the next turn starts then.
                pendingTime = time ?? pendingTime
                breakBefore = true
                continue
            }
            if let header = line.firstMatch(of: #/^(.{1,40}?)(?:\s{2,}|\t+|\s*(?=[\[(]))[\[(]?((?:\d+:)?\d{1,2}:\d{2})(?:[.,]\d+)?[\])]?$/#),
               isName(String(header.1), strict: true) {
                // "Name  0:15" on its own line (Otter): the turn's text follows.
                speaker = String(header.1)
                pendingTime = seconds(String(header.2))
                breakBefore = true
                continue
            }
            if let prefix = speakerPrefix(line, strict: true) {
                speaker = prefix.name
                let start = prefix.time ?? time ?? pendingTime
                pendingTime = nil
                if prefix.rest.isEmpty {
                    // "Name:" on its own line: the text follows.
                    pendingTime = start
                    breakBefore = true
                } else {
                    turns.append(.init(speaker: speaker, start: start, text: prefix.rest))
                    breakBefore = false
                }
                continue
            }

            let start = time ?? pendingTime
            pendingTime = nil
            if start == nil, !breakBefore, !turns.isEmpty {
                turns[turns.count - 1].text += " " + line
            } else {
                turns.append(.init(speaker: speaker, start: start, text: line))
            }
            breakBefore = false
        }
        return ImportedTranscript(format: .text, title: title, turns: turns)
    }

    // MARK: - Pieces

    /// `00:00:01.000 --> 00:00:03.500` (VTT) or `00:00:01,000 --> 00:00:03,500` (SRT); cue
    /// settings after the end time are ignored. A time past `longestStamp` is dropped, the
    /// cue kept: it then follows the cue before it.
    static func cueTiming(_ line: String) -> (start: TimeInterval?, end: TimeInterval?)? {
        guard let match = line.firstMatch(of: #/^\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})\s*-->\s*((?:\d+:)?\d{1,2}:\d{2}[.,]\d{1,3})/#)
        else { return nil }
        return (seconds(String(match.1)), seconds(String(match.2)))
    }

    /// No meeting runs 100 hours: a later time comes from a damaged file, and is dropped
    /// rather than stretching the meeting to it (FLU-27).
    static let longestStamp: TimeInterval = 100 * 3600

    /// `h:mm:ss`, `mm:ss`, with an optional `.ttt` or `,ttt` fraction; nil past
    /// `longestStamp`.
    static func seconds(_ stamp: String) -> TimeInterval? {
        let parts = stamp.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total: TimeInterval = 0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total <= longestStamp ? total : nil
    }

    /// `Name: text`, `Name (00:12): text`, `Name [00:12] : text`. The colon must be
    /// followed by a space or end the line, so `https://…` is not a speaker.
    static func speakerPrefix(_ line: String, strict: Bool) -> (name: String, time: TimeInterval?, rest: String)? {
        guard let match = line.firstMatch(of: #/^([^\s:\[\]()<>][^:\[\]()<>]{0,39}?)\s*(?:[\[(]((?:\d+:)?\d{1,2}:\d{2})(?:[.,]\d+)?[\])])?\s*:(?:\s+(.*))?$/#)
        else { return nil }
        let name = String(match.1).trimmingCharacters(in: .whitespaces)
        guard isName(name, strict: strict) else { return nil }
        let rest = match.3.map { String($0).trimmingCharacters(in: .whitespaces) } ?? ""
        return (name, match.2.flatMap { seconds(String($0)) }, rest)
    }

    /// A speaker name rather than the start of a sentence: at most five words, no sentence
    /// punctuation. In free text (`strict`) every word is also capitalised, a number
    /// ("Speaker 2") or a particle ("de", "van"), so "Prochaine étape : …" stays text;
    /// subtitle cues are lenient because Zoom writes whatever the account is called.
    static func isName(_ candidate: String, strict: Bool) -> Bool {
        let name = candidate.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.count <= 40, let first = name.first, first.isLetter,
              !name.contains(where: { ":?!;,\"«»“”".contains($0) })
        else { return false }
        let words = name.split(whereSeparator: \.isWhitespace)
        guard words.count <= 5, !isSectionLabel(name) else { return false }
        guard strict else { return true }
        let particles: Set<String> = ["de", "du", "des", "la", "le", "d'", "da", "di", "van", "von", "der", "den", "y", "e", "bin", "al"]
        return words.allSatisfy { word in
            guard let initial = word.first else { return false }
            return initial.isUppercase || word.allSatisfy(\.isNumber) || particles.contains(word.lowercased())
        }
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    // MARK: - Into a meeting

    /// The user's own name among a transcript's speakers: the same full name, or the same
    /// first name when only one speaker has it. Case and accents are ignored.
    public static func guessMe(in speakers: [String], userNames: [String]) -> String? {
        func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
                .trimmingCharacters(in: .whitespaces)
        }
        func firstName(_ text: String) -> String {
            fold(text).split(whereSeparator: { $0.isWhitespace || $0 == "." }).first.map(String.init) ?? ""
        }
        let full = Set(userNames.map(fold).filter { !$0.isEmpty })
        if let exact = speakers.first(where: { full.contains(fold($0)) }) { return exact }
        let firsts = Set(userNames.map(firstName).filter { !$0.isEmpty })
        let candidates = speakers.filter { firsts.contains(firstName($0)) }
        return candidates.count == 1 ? candidates[0] : nil
    }

    /// A finished meeting from a transcript. Named speakers keep their names (the user
    /// chose the file, so the names are theirs); `me` becomes the user; turns without a
    /// name share one unnamed speaker. Untimed turns follow each other at a speaking pace.
    public static func meeting(
        from transcript: ImportedTranscript,
        title: String,
        startedAt: Date,
        me: String?,
        sourceName: String? = nil
    ) -> Meeting {
        var ids: [String: String] = [:]
        var speakers: [Speaker] = []
        var next = 1
        if let me, transcript.speakers.contains(me) {
            ids[me] = Speaker.meID
            speakers.append(.me(named: me))
        }
        for name in transcript.speakers where ids[name] == nil {
            ids[name] = "S\(next)"
            speakers.append(Speaker(id: "S\(next)", name: name, nameSource: .user))
            next += 1
        }
        var unnamedID: String?
        func speakerID(_ name: String?) -> String {
            if let name, let id = ids[name] { return id }
            if let unnamedID { return unnamedID }
            let id = "S\(next)"
            next += 1
            unnamedID = id
            speakers.append(Speaker(id: id))
            return id
        }

        var segments: [TranscriptSegment] = []
        var clock: TimeInterval = 0
        let turns = transcript.turns
        for (index, turn) in turns.enumerated() {
            let start = max(0, turn.start ?? clock)
            let estimate = max(1, Double(turn.text.split(whereSeparator: \.isWhitespace).count) * secondsPerWord)
            let following = index + 1 < turns.count ? turns[index + 1].start : nil
            var end = turn.end ?? following ?? start + estimate
            if end <= start { end = start + estimate }
            let id = speakerID(turn.speaker)
            segments.append(TranscriptSegment(
                source: id == Speaker.meID ? .microphone : .system,
                speakerID: id,
                start: start,
                end: end,
                text: turn.text,
                isFinal: true
            ))
            clock = max(clock, end)
        }
        // Time-ordered, as a recorded meeting is; equal starts keep the file's order.
        segments = segments.enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element)

        return Meeting(
            title: title,
            trigger: .imported,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(segments.map(\.end).max() ?? 0),
            speakers: speakers,
            segments: segments,
            importedFrom: sourceName
        )
    }
}
