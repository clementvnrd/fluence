import Foundation

/// Development only (FLU-12): fills a scratch support folder with synthetic data for
/// screenshots, through the app's own stores — so the files are sealed exactly as real
/// ones are.
///
/// Runs only with `FLUENCE_SUPPORT_DIRECTORY` set (a scratch folder, see `AppPaths`) and
/// `FLUENCE_SEED_FILE` naming a JSON file there: `{"runs": [DictationRun], "meetings":
/// [Meeting], "snippets": [{"trigger", "expansion"}]}`, dates in ISO 8601. The sample text
/// lives in that file, never in the app. Seeds once per folder.
@MainActor
enum ScreenshotSeed {
    private struct Seed: Decodable {
        struct SnippetSeed: Decodable {
            var trigger: String
            var expansion: String
        }

        var runs: [DictationRun]?
        var meetings: [Meeting]?
        var snippets: [SnippetSeed]?
    }

    static func applyIfRequested() {
        guard let support = AppPaths.override,
              let path = ProcessInfo.processInfo.environment["FLUENCE_SEED_FILE"]
        else { return }
        let marker = support.appendingPathComponent(".seeded")
        guard !FileManager.default.fileExists(atPath: marker.path) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let seed = try? decoder.decode(Seed.self, from: data)
        else {
            Log.app.error("screenshot seed unreadable")
            return
        }
        for run in seed.runs ?? [] { RunLog.record(run) }
        for meeting in seed.meetings ?? [] { try? MeetingStore.shared.save(meeting) }
        for snippet in seed.snippets ?? [] { SnippetStore.shared.add(cue: snippet.trigger, expansion: snippet.expansion) }
        FileManager.default.createFile(atPath: marker.path, contents: Data())
        Log.app.info("screenshot seed applied")
    }
}
