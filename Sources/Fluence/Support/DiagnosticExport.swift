import AppKit
import FluenceCore
import Foundation
import SystemConfiguration
import UniformTypeIdentifiers

/// Réglages › À propos › « Exporter un diagnostic » (FLU-35): a text file the user saves
/// where they choose and sends if they want to. Nothing leaves the Mac on its own.
///
/// What goes in is listed here, field by field, from the app's own vocabulary — versions,
/// setting values, counts, timings, error kinds, crash report dates. `DiagnosticReport` then
/// refuses any value that is not a plain token and masks the home folder, the account name and
/// the Mac's name. The self-test plants a sentence in the history, the dictionary and the
/// snippets of a scratch account and checks it never reaches this file.
@MainActor
enum DiagnosticExport {
    /// Where macOS writes crash, hang and resource reports for the user's apps.
    static var crashReportFolders: [URL] {
        let reports = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        return [reports, reports.appendingPathComponent("Retired", isDirectory: true)]
    }

    /// The whole file. `includeSystemState` reads the permissions and the updater; the
    /// self-test leaves them out, as it never touches either.
    static func report(
        events: [DiagnosticEvent],
        crashReportFolders: [URL] = crashReportFolders,
        includeSystemState: Bool = true,
        now: Date = .now
    ) -> String {
        var input = DiagnosticReport.Input(generatedAt: now)
        input.app = appFacts(includeSystemState: includeSystemState)
        input.settings = settings()
        input.counts = counts(events: events, includeSystemState: includeSystemState, now: now)
        input.timings = timings()
        input.events = events
        input.crashReportFiles = crashReportFolders.flatMap {
            (try? FileManager.default.contentsOfDirectory(atPath: $0.path)) ?? []
        }
        input.redact = redactions()
        return DiagnosticReport.render(input)
    }

    /// « Fluence-diagnostic-2026-10-26.txt ».
    static var defaultFileName: String {
        let day = Date.now.formatted(.iso8601.year().month().day())
        return "Fluence-diagnostic-\(day).txt"
    }

    /// Asks where to save, then writes the file. Nil when the user cancelled.
    static func save() async throws -> URL? {
        let text = report(events: await DiagnosticsLog.shared.events())
        let panel = NSSavePanel()
        panel.title = "Exporter un diagnostic"
        panel.prompt = "Exporter"
        panel.nameFieldStringValue = defaultFileName
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try Data(text.utf8).write(to: url, options: [.atomic])
        return url
    }

    // MARK: - Fields

    private static func appFacts(includeSystemState: Bool) -> [(String, String)] {
        let info = Bundle.main.infoDictionary ?? [:]
        var facts: [(String, String)] = [
            ("version", info["CFBundleShortVersionString"] as? String ?? "—"),
            ("build", info["CFBundleVersion"] as? String ?? "—"),
            ("identity", identity),
            ("macOS", ProcessInfo.processInfo.operatingSystemVersionString),
            ("hardware", sysctlString("hw.model") ?? "—"),
            ("architecture", architecture),
            ("memoryGB", String(ProcessInfo.processInfo.physicalMemory >> 30)),
            ("publicBuild", isPublicBuild ? "yes" : "no"),
            ("installedInApplications", Bundle.main.bundlePath.hasPrefix("/Applications/") ? "yes" : "no"),
        ]
        if includeSystemState {
            facts.append(("updater", AppUpdater.shared.isRunning ? "on" : "off"))
        }
        return facts
    }

    private static func settings() -> [(String, String)] {
        let settings = Settings.shared
        let notetaker = NotetakerSettings.shared
        var values: [(String, String)] = [
            ("engine", settings.engine.rawValue),
            ("whisperModel", settings.whisperModel),
            ("compareMode", flag(settings.compareMode)),
            ("cleanupLevel", settings.cleanupLevel.rawValue),
            ("effectiveCleanupLevel", settings.effectiveCleanupLevel.rawValue),
            ("dictationLanguage", settings.dictationLanguage.rawValue),
            ("pushToTalkKey", settings.pushToTalkKey.rawValue),
            // A device UID can carry the device's name: only whether one was chosen.
            ("microphone", settings.selectedMicrophoneUID == "default" ? "system" : "chosen"),
            ("parakeetVocabularyBoost", flag(settings.parakeetVocabularyBoost)),
            ("learnFromEdits", flag(settings.learnFromEdits)),
            ("smartCleanupOnWhisper", flag(settings.smartCleanupOnWhisper)),
            ("appAwareStyles", flag(settings.appAwareStylesEnabled)),
            ("snippets", flag(settings.snippetsEnabled)),
            ("commandMode", flag(settings.commandModeEnabled)),
            ("commandModeKey", settings.commandModeKey.rawValue),
            ("learnFrequentTerms", flag(settings.learnFrequentTerms)),
            ("sound", flag(settings.soundEnabled)),
            ("historyRetention", settings.historyRetention.rawValue),
            ("maxRecordingMinutes", String(settings.maxRecordingMinutes)),
            ("lastTranscriptShortcuts", flag(settings.lastTranscriptShortcuts)),
            ("notetaker.detectMeetings", flag(notetaker.detectMeetings)),
            ("notetaker.autoRecordSeconds", String(notetaker.autoRecordSeconds)),
            ("notetaker.keepAudioByDefault", flag(notetaker.keepAudioByDefault)),
            ("notetaker.voicePrints", flag(notetaker.voicePrintsEnabled)),
            ("notetaker.readNamesFromMeetingWindow", flag(notetaker.readNamesFromMeetingWindow)),
            ("notetaker.useCalendar", flag(notetaker.useCalendar)),
            ("notetaker.retentionDays", notetaker.retentionDays.map(String.init) ?? "keep"),
            ("notetaker.maxDurationMinutes", String(notetaker.maxDurationMinutes)),
        ]
        for category in AppCategory.allCases {
            values.append(("style.\(category.rawValue)", settings.style(for: category).rawValue))
        }
        return values
    }

    private static func counts(events: [DiagnosticEvent], includeSystemState: Bool, now: Date) -> [(String, Int)] {
        let runs = RunStore.shared.runs
        let weekAgo = now.addingTimeInterval(-7 * 86_400)
        let dictionary = DictionaryStore.shared.entries
        let snippets = SnippetStore.shared.snippets
        let meetings = MeetingStore.shared.summaries
        var counts: [(String, Int)] = [
            ("dictations", runs.count),
            ("dictations.last7days", runs.filter { $0.date >= weekAgo }.count),
            ("dictations.withDictionaryCorrections", runs.filter { !($0.corrections ?? []).isEmpty }.count),
            ("comparisons", RunStore.shared.comparisons.count),
            ("history.problem", RunStore.shared.problem == nil ? 0 : 1),
            ("dictionary.entries", dictionary.count),
            ("dictionary.enabled", dictionary.filter(\.isEnabled).count),
            ("dictionary.corrections", dictionary.filter { $0.kind == .correction }.count),
            ("snippets", snippets.count),
            ("snippets.enabled", snippets.filter(\.isEnabled).count),
            ("snippets.problem", SnippetStore.shared.problem == nil ? 0 : 1),
            ("meetings", meetings.count),
            ("meetings.withNotes", meetings.filter(\.hasNotes).count),
            ("meetings.imported", meetings.filter { $0.isImported == true }.count),
            ("meetings.unreadableOrProblem", MeetingStore.shared.lastError == nil ? 0 : 1),
            ("events", events.count),
            ("events.errors", events.filter { $0.severity == .error }.count),
            ("events.recoveries", events.filter { $0.severity == .recovery }.count),
        ]
        if includeSystemState {
            counts.append(("permission.accessibility", Permissions.hasAccessibility ? 1 : 0))
            counts.append(("permission.microphone", Permissions.hasMicrophone ? 1 : 0))
        }
        return counts
    }

    /// Over the last 100 dictations and every stored meeting.
    private static func timings() -> [(String, Double)] {
        let recent = RunStore.shared.runs.suffix(100)
        var timings: [(String, Double)] = []
        func add(_ key: String, _ value: Double?) {
            if let value { timings.append((key, value)) }
        }
        add("dictation.audio.median", DiagnosticStats.percentile(recent.map(\.audioSeconds), 0.5))
        add("dictation.process.median", DiagnosticStats.percentile(recent.map(\.processSeconds), 0.5))
        add("dictation.process.p90", DiagnosticStats.percentile(recent.map(\.processSeconds), 0.9))
        for engine in SpeechEngineChoice.allCases {
            let runs = recent.filter { $0.engine == engine.displayName }
            add("dictation.process.median.\(engine.rawValue)", DiagnosticStats.percentile(runs.map(\.processSeconds), 0.5))
        }
        let durations = MeetingStore.shared.summaries.map(\.duration)
        add("meeting.duration.median", DiagnosticStats.percentile(durations, 0.5))
        add("meeting.duration.max", durations.max())
        return timings
    }

    /// The home folder, the account's short and full name (and each word of it), the Mac's
    /// name: masked wherever they would still appear.
    private static func redactions() -> [String] {
        var secrets = [NSHomeDirectory(), NSUserName(), NSFullUserName()]
        secrets += NSFullUserName().split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        if let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? {
            secrets.append(computer)
        }
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? {
            secrets.append(local)
        }
        return secrets.filter { !$0.isEmpty }
    }

    // MARK: - Helpers

    private static func flag(_ on: Bool) -> String { on ? "on" : "off" }

    /// "production", or the suffix of a test copy's bundle ID ("updatetest"). Not the ID
    /// itself: it holds Clement's GitHub name, which the report masks.
    private static var identity: String {
        let id = Bundle.main.bundleIdentifier ?? ""
        if id == AppPaths.productionBundleID { return "production" }
        let prefix = AppPaths.productionBundleID + "."
        return id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : "other"
    }

    private static var isPublicBuild: Bool {
        #if FLUENCE_WITHOUT_WISPR
        true
        #else
        false
        #endif
    }

    private static var architecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}
