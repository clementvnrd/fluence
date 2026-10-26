import FluenceCore
import FluenceDictionary
import Foundation
import Sparkle

/// `Fluence --selftest` (FLU-35): starts the release binary as CI builds it, opens the settings
/// and every store on a scratch account, exports a diagnostic, and exits — 0 when all is well.
///
/// It runs from `FluenceMain`, before SwiftUI, the app delegate and `SingleInstance`, so it
/// never brings a running Fluence forward, never creates a window, a shortcut, an event tap or
/// an audio engine, and never asks for a permission. And it never touches the user's data:
///
/// - `AppPaths.support` is a new folder in the temporary directory (`AppPaths.override`);
/// - the settings live in a `defaults.plist` inside it (`AppPaths.defaults`), not in the
///   app's preferences;
/// - the Vault seals with a key held in memory and never reads or creates the Keychain item.
///
/// The first step checks the first two; a failure there stops the run before any store opens.
enum SelfTest {
    static let isRequested = ProcessInfo.processInfo.arguments.dropFirst().contains("--selftest")

    /// Fresh for each run, removed when the run passes.
    static let folder: URL = FileManager.default.temporaryDirectory
        .appendingPathComponent("FluenceSelfTest-\(UUID().uuidString)", isDirectory: true)

    /// Planted in the scratch account's history, dictionary and snippets: none of its words may
    /// reach the diagnostic file.
    private static let planted = "Zéphyrin grignote quatorze clafoutis indigo chez Brocéliande"
    private static let plantedWords = ["Zéphyrin", "Zephyrin", "grignote", "quatorze", "clafoutis", "indigo", "Brocéliande", "Broceliande"]

    @MainActor
    static func run() -> Never {
        // Line by line, so a crash part-way still shows how far it got.
        setvbuf(stdout, nil, _IOLBF, 0)
        let started = Date()
        var failures = 0
        print("selftest: Fluence \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") — scratch folder \(folder.path)")

        func step(_ name: String, _ body: () throws -> String?) {
            let clock = Date()
            let problem: String?
            do {
                problem = try body()
            } catch {
                problem = "\(type(of: error)): \((error as NSError).domain) \((error as NSError).code)"
            }
            let ms = Int(Date().timeIntervalSince(clock) * 1000)
            if let problem {
                failures += 1
                print("selftest: FAIL \(name) — \(problem)")
            } else {
                print("selftest: ok   \(name) (\(ms) ms)")
            }
        }

        step("scratch data folder") {
            let support = AppPaths.support.resolvingSymlinksInPath().path
            let scratch = folder.resolvingSymlinksInPath().path
            guard support == scratch, AppPaths.isIsolated else { return "support folder is \(support)" }
            guard FileManager.default.fileExists(atPath: support) else { return "not created" }
            guard AppPaths.defaults !== UserDefaults.standard else { return "settings would go to the app's preferences" }
            AppPaths.defaults.set(true, forKey: "selftest")
            AppPaths.defaults.synchronize()
            guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("defaults.plist").path) else {
                return "settings file not in the scratch folder"
            }
            return nil
        }
        // Nothing below may run against the real account.
        guard failures == 0 else { finish(started: started, failures: failures) }

        step("vault (in-memory key)") {
            let sealed = try Vault.seal(Data("selftest".utf8))
            return try Vault.open(sealed) == Data("selftest".utf8) ? nil : "round trip differs"
        }

        step("bundle version") {
            let bundle = Bundle.main
            guard bundle.bundleURL.pathExtension == "app" else {
                print("selftest:      not run from an app bundle: version not checked")
                return nil
            }
            let short = bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            let build = bundle.infoDictionary?["CFBundleVersion"] as? String ?? ""
            guard let version = ReleaseVersion(short) else { return "CFBundleShortVersionString '\(short)'" }
            return build == String(version.buildNumber) ? nil : "CFBundleVersion \(build), expected \(version.buildNumber)"
        }

        step("sparkle framework") {
            let framework = Bundle(for: SPUUpdater.self)
            guard framework.bundlePath.hasSuffix("Sparkle.framework") else { return "loaded from \(framework.bundlePath)" }
            if Bundle.main.bundleURL.pathExtension == "app",
               let frameworks = Bundle.main.privateFrameworksURL?.resolvingSymlinksInPath().path,
               !framework.bundleURL.resolvingSymlinksInPath().path.hasPrefix(frameworks) {
                return "not the copy embedded in the app"
            }
            return nil
        }

        step("settings") {
            _ = Settings.shared.engine
            _ = NotetakerSettings.shared.detectMeetings
            return nil
        }

        step("dictionary") {
            let store = DictionaryStore.shared
            guard !store.entries.isEmpty else { return "no entries (the lexicon should seed it)" }
            store.add(DictionaryEntry(kind: .correction, write: "Brocéliande", hear: "brosse et liane"))
            let text = try String(contentsOf: DictionaryStore.fileURL, encoding: .utf8)
            return text.contains("Brocéliande") ? nil : "entry not saved"
        }

        step("snippets") {
            let store = SnippetStore.shared
            store.add(cue: "zéphyrin", expansion: planted)
            guard waitUntil({ FileManager.default.fileExists(atPath: SnippetStore.fileURL.path) }) else {
                return store.problem.map { _ in "store reports a problem" } ?? "file not written"
            }
            return store.problem == nil ? nil : "store reports a problem"
        }

        step("history") {
            RunLog.start()
            RunLog.record(DictationRun(
                date: Date(),
                engine: SpeechEngineChoice.parakeet.displayName,
                audioSeconds: 2.5,
                processSeconds: 0.4,
                text: planted,
                rawText: planted.lowercased()
            ))
            let file = AppPaths.support.appendingPathComponent("history.sealed")
            guard waitUntil({ FileManager.default.fileExists(atPath: file.path) }) else { return "file not written" }
            guard waitUntil({ RunStore.shared.runs.count == 1 }) else { return "\(RunStore.shared.runs.count) runs in memory" }
            return RunStore.shared.problem == nil ? nil : "store reports a problem"
        }

        step("meetings") {
            let store = MeetingStore.shared
            guard store.root.resolvingSymlinksInPath().path.hasPrefix(folder.resolvingSymlinksInPath().path) else {
                return "meetings outside the scratch folder"
            }
            return store.summaries.isEmpty && store.lastError == nil ? nil : "unexpected state"
        }

        step("diagnostic log") {
            Diagnostics.recovery("selftest.recorded")
            DiagnosticsLog.shared.flush()
            let file = AppPaths.support.appendingPathComponent("diagnostics.sealed")
            let ring = DiagnosticRing.decoded(try Vault.read(file))
            return ring?.events.contains { $0.kind == "selftest.recorded" } == true ? nil : "event not read back"
        }

        step("diagnostic export") {
            // A crash report folder of its own, with a name macOS could write: the Mac's name in
            // it must not come out either.
            let reports = folder.appendingPathComponent("DiagnosticReports", isDirectory: true)
            try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
            for name in ["Fluence_2026-10-08-101500_MacBook-de-Zephyrin.diag", "Other-2026-10-08-101500.ips"] {
                FileManager.default.createFile(atPath: reports.appendingPathComponent(name).path, contents: Data())
            }
            let events = DiagnosticsLog.shared.snapshot()
            let output = folder.appendingPathComponent("diagnostic.txt")
            let report = DiagnosticExport.report(events: events, crashReportFolders: [reports], includeSystemState: false)
            try Data(report.utf8).write(to: output, options: [.atomic])
            let written = try String(contentsOf: output, encoding: .utf8)

            let leaked = plantedWords.filter { written.localizedCaseInsensitiveContains($0) }
            guard leaked.isEmpty else { return "planted words in the file: \(leaked.count)" }
            guard !written.contains(folder.path), !written.contains(NSHomeDirectory()) else { return "a path is in the file" }
            for expected in ["dictations: 1", "snippets: 1", "selftest.recorded", "Fluence-2026-10-08-101500.diag", "[crash reports] 1"] {
                guard written.contains(expected) else { return "missing '\(expected)'" }
            }
            print("selftest:      diagnostic: \(written.split(separator: "\n").count) lines, \(written.utf8.count) bytes, no planted word")
            // The scratch account's file, in the log: what an export looks like, for review.
            for line in written.split(separator: "\n", omittingEmptySubsequences: false) {
                print("selftest:      > \(line)")
            }
            return nil
        }

        finish(started: started, failures: failures)
    }

    @MainActor
    private static func finish(started: Date, failures: Int) -> Never {
        let seconds = String(format: "%.2f", Date().timeIntervalSince(started))
        if failures == 0 {
            try? FileManager.default.removeItem(at: folder)
            print("selftest: passed in \(seconds) s")
            exit(0)
        }
        print("selftest: FAILED — \(failures) step(s), \(seconds) s; scratch folder kept at \(folder.path)")
        exit(1)
    }

    /// Lets the main queue run (the stores report back on it) until `condition` holds.
    @MainActor
    private static func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else { return false }
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return true
    }
}
