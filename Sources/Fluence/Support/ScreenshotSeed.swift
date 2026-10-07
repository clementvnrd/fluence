import AppKit
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

/// Development only (FLU-12): opens the windows on a given page for screenshots, under
/// `FLUENCE_SUPPORT_DIRECTORY` only. `FLUENCE_PREVIEW_SECTION` (transcriptions, dictionary,
/// snippets, styles, meetings, upcoming), `FLUENCE_PREVIEW_MEETING` (index in the list) with
/// `FLUENCE_PREVIEW_MEETING_TAB` (notes, transcript, myNotes) and `FLUENCE_PREVIEW_RENAME`
/// (a speaker ID), `FLUENCE_PREVIEW_SETTINGS` (a `SettingsSection` raw value), `FLUENCE_PREVIEW_ONBOARDING`
/// (a step number), `FLUENCE_PREVIEW_IMPORT` (see `openImportIfRequested`),
/// `FLUENCE_PREVIEW_SNAPSHOT` (see `snapshotIfRequested`).
@MainActor
enum DevPreview {
    private static var env: [String: String]? {
        AppPaths.override == nil ? nil : ProcessInfo.processInfo.environment
    }

    static var section: MainNavigation.Section? {
        switch env?["FLUENCE_PREVIEW_SECTION"] {
        case "transcriptions": .transcriptions
        case "dictionary": .dictionary
        case "snippets": .snippets
        case "styles": .styles
        case "meetings": .meetings
        case "upcoming": .upcoming
        default: nil
        }
    }

    /// `FLUENCE_PREVIEW_ONBOARDING`: opens the onboarding on that step (0 = Accessibilité).
    static var onboardingStep: Int? {
        env?["FLUENCE_PREVIEW_ONBOARDING"].flatMap(Int.init)
    }

    static var settingsSection: SettingsSection? {
        env?["FLUENCE_PREVIEW_SETTINGS"].flatMap(SettingsSection.init(rawValue:))
    }

    /// Opens the requested meeting page once the store has loaded.
    static func openMeetingIfRequested(_ model: MeetingLibraryModel) {
        guard let env, let index = env["FLUENCE_PREVIEW_MEETING"].flatMap(Int.init),
              model.store.summaries.indices.contains(index) else { return }
        model.openPage(model.store.summaries[index].id)
        if let tab = env["FLUENCE_PREVIEW_MEETING_TAB"].flatMap(MeetingLibraryModel.Tab.init(rawValue:)) {
            model.tab = tab
        }
        if let id = env["FLUENCE_PREVIEW_RENAME"], let speaker = model.meeting?.speaker(id) {
            model.beginRenaming(speaker)
        }
    }

    /// `FLUENCE_PREVIEW_IMPORT`: opens the import sheet on these files (paths separated by
    /// `:`), or on its first step when the value is `sheet`.
    static func openImportIfRequested(_ model: MeetingLibraryModel) {
        guard let env, let value = env["FLUENCE_PREVIEW_IMPORT"] else { return }
        if value == "sheet" {
            model.importer.begin()
        } else {
            model.importer.open(value.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
            // `FLUENCE_PREVIEW_IMPORT_COMMIT=1`: saves every draft as is, which starts the
            // notes — for testing long meetings end to end on synthetic transcripts.
            if env["FLUENCE_PREVIEW_IMPORT_COMMIT"] == "1" {
                while model.importer.draft != nil {
                    model.importer.commit(store: model.store, generator: model.generator)
                }
            }
        }
    }

    /// `FLUENCE_PREVIEW_SNAPSHOT` (a folder): after `FLUENCE_PREVIEW_SNAPSHOT_DELAY` seconds
    /// (default 4), draws every visible window of this process into `<folder>/<n>-<title>.png`.
    /// The app draws its own windows, so no screen-recording permission is involved and no
    /// other app is ever captured.
    static func snapshotIfRequested() {
        guard let env, let folder = env["FLUENCE_PREVIEW_SNAPSHOT"] else { return }
        let delay = env["FLUENCE_PREVIEW_SNAPSHOT_DELAY"].flatMap(Double.init) ?? 4
        if env["FLUENCE_PREVIEW_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        Task { @MainActor in
            // `FLUENCE_PREVIEW_WINDOW_SIZE` ("880x580"): every titled window takes this content
            // size first, to check layouts at the sizes people actually use (FLU-18).
            if let size = env["FLUENCE_PREVIEW_WINDOW_SIZE"].flatMap(Self.size(from:)) {
                try? await Task.sleep(for: .seconds(delay / 2))
                for window in NSApp.windows where window.isVisible && window.styleMask.contains(.titled) {
                    // `setFrame` on purpose: it bypasses the content size limits, the way a
                    // restored window frame does.
                    var frame = window.frame
                    frame.size = window.frameRect(forContentRect: NSRect(origin: .zero, size: size)).size
                    window.setFrame(frame, display: true)
                }
            }
            try? await Task.sleep(for: .seconds(delay))
            let directory = URL(fileURLWithPath: folder, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (index, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView else { continue }
                let bounds = view.bounds
                guard bounds.width > 1, bounds.height > 1,
                      let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
                view.cacheDisplay(in: bounds, to: rep)
                let name = window.title.isEmpty ? String(describing: type(of: window)) : window.title
                let safe = name.filter { $0.isLetter || $0.isNumber }
                let url = directory.appendingPathComponent("\(index)-\(safe).png")
                try? rep.representation(using: .png, properties: [:])?.write(to: url)
            }
            Log.app.info("preview snapshots written")
        }
    }

    private static func size(from text: String) -> CGSize? {
        let parts = text.split(separator: "x").compactMap { Double($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return CGSize(width: parts[0], height: parts[1])
    }
}
