import FluenceMeetingCore
import Foundation

/// Granola's local cache (FLU-144), `cache-v3.json`: an object whose `cache` field holds, as a
/// JSON string (or an object), `state.documents` — `{id, title, created_at, deleted_at,
/// notes_markdown, notes_plain}` by id — and `state.transcripts` — by document id, lines
/// `{text, source: microphone | system, start_timestamp, end_timestamp}`. Written from the
/// format's public descriptions and synthetic fixtures: no Granola install was available.
public enum GranolaSource {
    public static func read(_ file: Data) throws -> ForeignData {
        guard let outer = try? JSONSerialization.jsonObject(with: file) as? [String: Any] else { throw ImportFailure.unreadable }
        var cache = outer["cache"] ?? outer
        if let text = cache as? String {
            guard let inner = try? JSONSerialization.jsonObject(with: Data(text.utf8)) else { throw ImportFailure.unreadable }
            cache = inner
        }
        guard let state = (cache as? [String: Any])?["state"] as? [String: Any] else { throw ImportFailure.unreadable }
        let transcripts = state["transcripts"] as? [String: Any] ?? [:]

        var data = ForeignData(app: .granola)
        for document in values(state["documents"]) {
            guard let id = document["id"] as? String, document["deleted_at"] as? String == nil,
                  let start = (document["created_at"] as? String).flatMap(ForeignDates.iso) else { continue }
            let notes = (document["notes_markdown"] as? String)?.nonBlank ?? (document["notes_plain"] as? String)?.nonBlank ?? ""
            let lines = (transcripts[id] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
            let origin = lines.compactMap { ($0["start_timestamp"] as? String).flatMap(ForeignDates.iso) }.min() ?? start
            let turns: [ImportedTranscript.Turn] = lines.compactMap { line in
                guard let text = (line["text"] as? String)?.nonBlank else { return nil }
                func offset(_ key: String) -> TimeInterval? {
                    (line[key] as? String).flatMap(ForeignDates.iso).map { max(0, $0.timeIntervalSince(origin)) }
                }
                return .init(
                    speaker: line["source"] as? String == "microphone" ? Placeholder.me : Placeholder.voice("system"),
                    start: offset("start_timestamp"), end: offset("end_timestamp"),
                    text: text.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
            guard !turns.isEmpty || !notes.isEmpty else { continue }
            data.meetings.append(ForeignMeeting(
                id: StableID.uuid("granola:document:\(id)"),
                title: (document["title"] as? String)?.nonBlank ?? "",
                startedAt: turns.isEmpty ? start : origin,
                transcript: ImportedTranscript(format: .text, turns: turns),
                userNotes: notes
            ))
        }
        return data
    }

    /// `documents` keyed by id, or a plain list.
    private static func values(_ any: Any?) -> [[String: Any]] {
        if let byID = any as? [String: Any] { return byID.keys.sorted().compactMap { byID[$0] as? [String: Any] } }
        return (any as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    }
}
