import FluenceDictionary
import FluenceMeetingCore
import Foundation

/// superwhisper's local data (FLU-144): `settings/settings.json` (`vocabulary`: words,
/// `replacements`: `{original, with}`) and one folder per recording holding `meta.json`
/// (`datetime` in UTC, `duration` in milliseconds, `kind`, `result` / `llmResult` / `rawResult`,
/// `segments`). Only read.
public enum SuperwhisperSource {
    public static func read(settings: URL?, recordingsFolders: [URL]) -> ForeignData {
        var data = ForeignData(app: .superwhisper)
        if let settings, let object = json(settings) {
            for word in object["vocabulary"] as? [Any] ?? [] {
                let text = (word as? String) ?? ((word as? [String: Any])?["text"] as? String)
                if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    data.entries.append(.term(text))
                }
            }
            for case let replacement as [String: Any] in object["replacements"] as? [Any] ?? [] {
                guard let hear = (replacement["original"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !hear.isEmpty,
                      let write = (replacement["with"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !write.isEmpty
                else { continue }
                data.entries.append(.correction(hear: hear, write: write))
            }
        }

        for folder in recordingsFolders {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            for name in names.sorted() {
                guard let meta = json(folder.appendingPathComponent(name).appendingPathComponent("meta.json")),
                      let date = (meta["datetime"] as? String).flatMap(ForeignDates.iso),
                      let text = ["result", "llmResult", "rawResult"].lazy.compactMap({ (meta[$0] as? String)?.nonBlank }).first
                else { continue }
                let seconds = ((meta["duration"] as? Double) ?? 0) / 1000
                if (meta["kind"] as? String)?.lowercased() == "meeting" {
                    data.meetings.append(ForeignMeeting(
                        id: StableID.uuid("superwhisper:recording:\(name)"), title: "", startedAt: date,
                        endedAt: seconds > 0 ? date.addingTimeInterval(seconds) : nil,
                        transcript: ImportedTranscript(format: .text, turns: turns(meta["segments"]) ?? [.init(speaker: nil, text: text)])
                    ))
                } else {
                    data.dictations.append(ForeignDictation(
                        id: StableID.uuid("superwhisper:recording:\(name)"), date: date,
                        text: text.trimmingCharacters(in: .whitespacesAndNewlines), seconds: seconds
                    ))
                }
            }
        }
        return data
    }

    /// `segments: [{start, end, text, speaker?}]`, seconds from the start; nil when there are none.
    static func turns(_ segments: Any?) -> [ImportedTranscript.Turn]? {
        let turns: [ImportedTranscript.Turn] = (segments as? [Any] ?? []).compactMap { item in
            guard let segment = item as? [String: Any], let text = (segment["text"] as? String)?.nonBlank else { return nil }
            let speaker = segment["speaker"].map { "\($0)" }.map(Placeholder.voice)
            return .init(speaker: speaker, start: segment["start"] as? Double, end: segment["end"] as? Double,
                         text: text.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return turns.isEmpty ? nil : turns
    }

    private static func json(_ url: URL) -> [String: Any]? {
        (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}
