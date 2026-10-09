import FluenceCore
import FluenceDictionary
import Foundation
import Observation

/// One completed dictation.
struct DictationRun: Codable, Sendable, Identifiable {
    /// Stable identity, so a single run can be deleted without matching on its text.
    ///
    /// Decoded leniently: runs written before this existed have no `id` field, and failing
    /// their whole line would throw away the user's history to add a delete button. Those
    /// get a fresh id on load, which is then persisted the next time the file is rewritten.
    var id: UUID = UUID()

    let date: Date
    let engine: String
    /// How long the key was held.
    let audioSeconds: Double
    /// Release → final text ready. This is the latency you actually feel.
    let processSeconds: Double
    /// What was typed: after cleanup and the dictionary.
    let text: String
    /// What the engine heard, before cleanup. Kept only when cleanup changed it, so that a
    /// cleanup pass that drops a sentence never costs the user the words they spoke.
    var rawText: String?
    /// Shared by every engine that processed the same recording, so the comparison window
    /// can present them as one side-by-side comparison instead of unrelated rows.
    var group: String?

    /// Dictionary corrections that fired on this transcript. Recorded so history can show
    /// whether the dictionary is actually doing anything, rather than leaving it to faith.
    ///
    /// Optional for backwards compatibility: runs recorded before the dictionary existed
    /// decode with this nil rather than failing the whole line.
    var corrections: [AppliedCorrection]?

    var realtimeFactor: Double { audioSeconds / max(processSeconds, 0.0001) }
    var characters: Int { text.count }

    init(
        id: UUID = UUID(),
        date: Date,
        engine: String,
        audioSeconds: Double,
        processSeconds: Double,
        text: String,
        rawText: String? = nil,
        group: String? = nil,
        corrections: [AppliedCorrection]? = nil
    ) {
        self.id = id
        self.date = date
        self.engine = engine
        self.audioSeconds = audioSeconds
        self.processSeconds = processSeconds
        self.text = text
        self.rawText = rawText
        self.group = group
        self.corrections = corrections
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        date = try container.decode(Date.self, forKey: .date)
        engine = try container.decode(String.self, forKey: .engine)
        audioSeconds = try container.decode(Double.self, forKey: .audioSeconds)
        processSeconds = try container.decode(Double.self, forKey: .processSeconds)
        text = try container.decode(String.self, forKey: .text)
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        group = try container.decodeIfPresent(String.self, forKey: .group)
        corrections = try container.decodeIfPresent([AppliedCorrection].self, forKey: .corrections)
    }
}

/// The history as the windows see it: in memory, always current, never waiting on disk.
@MainActor
@Observable
final class RunStore {
    static let shared = RunStore()

    private(set) var runs: [DictationRun] = []

    /// Why history isn't being read or saved, when it isn't — typically the Keychain refusing
    /// the encryption key. Shown in the window, the menu and Settings, because the
    /// alternative failure mode is history that looks merely empty.
    fileprivate(set) var problem: String?

    private var hasLoaded = false

    private init() {}

    /// Recordings grouped by comparison, newest first.
    var comparisons: [[DictationRun]] {
        Dictionary(grouping: runs.filter { $0.group != nil }, by: { $0.group! })
            .values
            .sorted { ($0.first?.date ?? .distantPast) > ($1.first?.date ?? .distantPast) }
    }

    var singles: [DictationRun] {
        runs.filter { $0.group == nil }.reversed()
    }

    fileprivate func loaded(_ stored: [DictationRun]) {
        // Anything recorded while the file was still being read is newer than all of it.
        runs = hasLoaded ? runs : stored + runs
        hasLoaded = true
    }

    fileprivate func append(_ run: DictationRun) { runs.append(run) }
    fileprivate func removeAll(where predicate: (DictationRun) -> Bool) { runs.removeAll(where: predicate) }
}

/// Files finished dictations: into `RunStore` immediately, and onto disk — encrypted — in
/// the background.
///
/// Nothing here blocks the dictation path. Sealing, the Keychain round trip and any rewrite
/// run on `HistoryFile`'s own queue, after the text has already been typed.
@MainActor
enum RunLog {
    private static var retention: HistoryRetention { Settings.shared.historyRetention }

    /// Reads the history at launch, migrating the old plaintext files on the way, then
    /// applies the retention setting.
    static func start() {
        HistoryFile.shared.load { result in
            switch result {
            case .success(let runs):
                RunStore.shared.loaded(runs)
                applyRetention()
            case .failure(let message):
                RunStore.shared.loaded([])
                report(message)
            }
        }
    }

    static func record(_ run: DictationRun) {
        RunStore.shared.append(run)
        if retention.persists {
            HistoryFile.shared.append(run, then: report)
        }
        applyRetention()
    }

    /// Drops whatever the retention setting no longer allows, in memory and on disk.
    ///
    /// "Don't keep" leaves this session's runs in memory — the windows would otherwise go
    /// blank mid-session and compare mode would have nowhere to show its results — but
    /// removes the file outright.
    static func applyRetention() {
        let retention = self.retention
        let now = Date()
        if retention.persists {
            RunStore.shared.removeAll { !retention.keeps($0.date, now: now) }
        }
        HistoryFile.shared.purge(retention, now: now, then: report)
    }

    /// Deletes one run.
    static func delete(_ run: DictationRun) {
        delete(ids: [run.id])
    }

    /// Deletes every run in a comparison group — the engines all transcribed one utterance,
    /// so removing that utterance means removing all of its rows.
    static func deleteGroup(_ group: String) {
        RunStore.shared.removeAll { $0.group == group }
        HistoryFile.shared.remove(where: { $0.group == group }, then: report)
    }

    static func delete(ids: Set<UUID>) {
        RunStore.shared.removeAll { ids.contains($0.id) }
        HistoryFile.shared.remove(where: { ids.contains($0.id) }, then: report)
    }

    static func clear() {
        RunStore.shared.removeAll { _ in true }
        HistoryFile.shared.clear(then: report)
    }

    /// nil clears a previous problem: the last disk operation succeeded.
    private static func report(_ problem: String?) {
        if let problem { Log.app.error("history: \(problem)") }
        RunStore.shared.problem = problem
    }
}
