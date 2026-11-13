import FluenceCore
import FluenceDictionary
import FluenceMeetingCore
import Foundation

/// Wispr Flow's local data (FLU-144): `flow.sqlite` (tables `Dictionary`, `History`,
/// `Meetings`, `Notes`) and, per meeting, `meetings/<id>/refined.ndjson` — one JSON object per
/// line, `{speaker: {id, name}, text, timestamp: "mm:ss"}` — or `live.ndjson` when the refined
/// pass never ran (`startRecordingMs`). Both are opened read-only and never changed.
///
/// An explicit import on the user's click, in every build: no part of compare mode's reader.
public enum WisprFlowSource {
    /// `History.status` values whose row holds no dictation the user kept.
    static let failedStatuses: Set<String> = ["dismissed", "no_audio", "failed", "error"]

    public static func read(database: URL, meetingsFolder: URL) throws -> ForeignData {
        let db = try ReadOnlyDatabase(database)
        var data = ForeignData(app: .wisprFlow)

        for row in try db.rows("Dictionary", ["id", "phrase", "replacement", "isSnippet", "isDeleted", "createdAt"])
        where !row.flag("isDeleted") {
            guard let phrase = row.text("phrase")?.trimmingCharacters(in: .whitespacesAndNewlines), !phrase.isEmpty,
                  let id = row.text("id") else { continue }
            let replacement = row.text("replacement")?.nonBlank
            if row.flag("isSnippet") {
                guard let replacement else { continue }
                let snippet = Snippet(
                    id: StableID.uuid("wisprflow:snippet:\(id)"), trigger: phrase, expansion: replacement,
                    createdAt: row.text("createdAt").flatMap(ForeignDates.wispr)
                )
                if snippet.problem(among: []) == nil { data.snippets.append(snippet) }
            } else if let replacement = replacement?.trimmingCharacters(in: .whitespacesAndNewlines),
                      replacement.lowercased() != phrase.lowercased() {
                data.entries.append(.correction(hear: phrase, write: replacement))
            } else {
                data.entries.append(.term(phrase))
            }
        }

        let historyColumns = ["transcriptEntityId", "asrText", "formattedText", "editedText", "pastedText", "timestamp", "duration", "status"]
        for row in try db.rows("History", historyColumns) {
            guard !failedStatuses.contains(row.text("status") ?? ""),
                  let id = row.text("transcriptEntityId"),
                  let date = row.text("timestamp").flatMap(ForeignDates.wispr),
                  // What the user really got: their edit, what was pasted, the cleanup, the raw text.
                  let text = ["editedText", "pastedText", "formattedText", "asrText"].lazy.compactMap({ row.text($0)?.nonBlank }).first
            else { continue }
            data.dictations.append(ForeignDictation(
                id: StableID.uuid("wisprflow:dictation:\(id)"), date: date,
                text: text.trimmingCharacters(in: .whitespacesAndNewlines), seconds: max(0, row.number("duration") ?? 0)
            ))
        }

        let meetingColumns = ["id", "title", "createdAt", "endedAt", "isDeleted", "notes", "summary", "speakerMap", "transcriptDeletedAt"]
        for row in try db.rows("Meetings", meetingColumns) where !row.flag("isDeleted") {
            guard let id = row.text("id"), let start = row.text("createdAt").flatMap(ForeignDates.wispr) else { continue }
            let deleted = row.text("transcriptDeletedAt") != nil
            let names = speakerNames(row.text("speakerMap"))
            let turns = deleted ? [] : transcript(in: meetingsFolder.appendingPathComponent(id, isDirectory: true), names: names)
            let notes = row.text("notes")?.nonBlank ?? ""
            let summary = row.text("summary")?.nonBlank
            guard !turns.isEmpty || !notes.isEmpty || summary != nil else { continue }
            data.meetings.append(ForeignMeeting(
                id: StableID.uuid("wisprflow:meeting:\(id)"),
                title: row.text("title")?.nonBlank ?? "",
                startedAt: start,
                // Epoch milliseconds.
                endedAt: row.number("endedAt").map { Date(timeIntervalSince1970: $0 / 1000) }.flatMap { $0 > start ? $0 : nil },
                transcript: ImportedTranscript(format: .text, turns: turns),
                userNotes: notes,
                summary: summary
            ))
        }

        for row in try db.rows("Notes", ["id", "title", "content", "createdAt", "isDeleted"]) where !row.flag("isDeleted") {
            guard let id = row.text("id"), let content = row.text("content")?.nonBlank,
                  let date = row.text("createdAt").flatMap(ForeignDates.wispr) else { continue }
            data.meetings.append(ForeignMeeting(
                id: StableID.uuid("wisprflow:note:\(id)"), title: row.text("title")?.nonBlank ?? "",
                startedAt: date, userNotes: content, isNote: true
            ))
        }
        return data
    }

    /// `speakerMap`: `{assignments: {"1": {user, consensus, llm, dom, mic}}, people: {<person>: {name}}}`,
    /// the person the user chose first, then Wispr's guesses.
    static func speakerNames(_ json: String?) -> [String: String] {
        guard let data = json?.data(using: .utf8),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let assignments = map["assignments"] as? [String: Any]
        else { return [:] }
        let people = map["people"] as? [String: Any] ?? [:]
        var names: [String: String] = [:]
        for case let (speaker, assignment as [String: Any]) in assignments {
            let person = ["user", "consensus", "llm", "dom", "mic"].lazy.compactMap { assignment[$0] as? String }.first
            if let person, let name = (people[person] as? [String: Any])?["name"] as? String, let name = name.nonBlank {
                names[speaker] = name
            }
        }
        return names
    }

    /// `mm:ss` or `h:mm:ss`, as `refined.ndjson` stamps its lines (minutes go past 59).
    static func clock(_ stamp: String) -> TimeInterval? {
        let parts = stamp.split(separator: ":").map { Double($0) }
        guard (2...3).contains(parts.count), !parts.contains(nil) else { return nil }
        return parts.reduce(0) { $0 * 60 + $1! }
    }

    /// The refined transcript, else the live one.
    static func transcript(in folder: URL, names: [String: String]) -> [ImportedTranscript.Turn] {
        for file in ["refined.ndjson", "live.ndjson"] {
            guard let raw = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else { continue }
            var turns: [ImportedTranscript.Turn] = []
            for line in raw.split(whereSeparator: \.isNewline) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let text = (object["text"] as? String)?.nonBlank else { continue }
                let speaker = object["speaker"] as? [String: Any]
                let id = (speaker?["id"]).map { "\($0)" } ?? "?"
                let name = names[id] ?? (speaker?["name"] as? String)?.nonBlank ?? Placeholder.voice(id)
                let start = (object["startRecordingMs"] as? Double).map { $0 / 1000 }
                    ?? (object["timestamp"] as? String).flatMap(clock)
                let end = (object["endRecordingMs"] as? Double).map { $0 / 1000 }
                turns.append(.init(speaker: name, start: start, end: end, text: text.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            if !turns.isEmpty { return turns }
        }
        return []
    }
}
