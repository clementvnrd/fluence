import FluenceCore
import Foundation
import Observation

/// Which speech engine transcribes an utterance.
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case parakeet

    var displayName: String {
        switch self {
        case .apple: "Apple (streaming)"
        case .parakeet: "Parakeet (batch)"
        }
    }

    /// Apple shows text while you talk; Parakeet only resolves on release.
    var showsLiveText: Bool { self == .apple }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    var pushToTalkKey: PushToTalkKey {
        didSet { defaults.set(pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey) }
    }

    var engine: SpeechEngineChoice {
        didSet { defaults.set(engine.rawValue, forKey: Keys.engine) }
    }

    /// Run every engine on each recording and show them side by side, instead of
    /// transcribing with one. Nothing is typed into the focused app in this mode.
    var compareMode: Bool {
        didSet { defaults.set(compareMode, forKey: Keys.compareMode) }
    }

    /// Run the cleanup pass before injecting. Off = raw engine output.
    var cleanupEnabled: Bool {
        didSet { defaults.set(cleanupEnabled, forKey: Keys.cleanupEnabled) }
    }

    /// Use the on-device LLM for cleanup instead of the deterministic rule pass.
    var smartCleanup: Bool {
        didSet { defaults.set(smartCleanup, forKey: Keys.smartCleanup) }
    }

    /// Play a short tick when capture starts and stops.
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    /// How long finished dictations stay on disk. Applied at launch, after every run and
    /// whenever it changes.
    var historyRetention: HistoryRetention {
        didSet { defaults.set(historyRetention.rawValue, forKey: Keys.historyRetention) }
    }

    /// A dictation still running after this long is finished automatically. The backstop
    /// for a key-up that never arrives: without it a lost release means an open mic, an
    /// ever-growing buffer, and text typed into whatever has focus much later.
    var maxRecordingMinutes: Int {
        didSet { defaults.set(maxRecordingMinutes, forKey: Keys.maxRecordingMinutes) }
    }

    static let recordingLimitChoices = [2, 5, 10, 30]

    // MARK: FLU-5 input

    /// Held with the push-to-talk key, turns the hold into a Command Mode instruction.
    var commandModifier: CommandModifier {
        didSet { defaults.set(commandModifier.rawValue, forKey: Keys.commandModifier) }
    }

    /// ⌃⌘V pastes and ⌃⌘C copies the last transcript. Switchable because the chords are
    /// global: someone whose editor already uses them needs a way to give them back.
    var lastTranscriptShortcuts: Bool {
        didSet { defaults.set(lastTranscriptShortcuts, forKey: Keys.lastTranscriptShortcuts) }
    }

    // MARK: end FLU-5 input

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        static let smartCleanup = "smartCleanup"
        static let compareMode = "compareMode"
        static let historyRetention = "historyRetention"
        static let maxRecordingMinutes = "maxRecordingMinutes"
        // MARK: FLU-5 input
        static let commandModifier = "commandModifier"
        static let lastTranscriptShortcuts = "lastTranscriptShortcuts"
    }

    private init() {
        // Before the first read: settings chosen under the app's previous name carry over.
        LegacyMigration.migrateDefaults(into: defaults)
        let raw = defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.rightOption.rawValue
        pushToTalkKey = PushToTalkKey(rawValue: raw) ?? .rightOption
        // Apple by default: no download, no dependency, live text while speaking.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        smartCleanup = defaults.object(forKey: Keys.smartCleanup) as? Bool ?? false
        compareMode = defaults.object(forKey: Keys.compareMode) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        historyRetention = HistoryRetention(rawValue: defaults.string(forKey: Keys.historyRetention) ?? "")
            ?? .default
        let limit = defaults.integer(forKey: Keys.maxRecordingMinutes)
        maxRecordingMinutes = limit > 0 ? limit : 10
        // MARK: FLU-5 input
        commandModifier = CommandModifier(rawValue: defaults.string(forKey: Keys.commandModifier) ?? "") ?? .control
        lastTranscriptShortcuts = defaults.object(forKey: Keys.lastTranscriptShortcuts) as? Bool ?? true
    }
}

extension HistoryRetention {
    var displayName: String {
        switch self {
        case .never: "Don't keep"
        case .day: "1 day"
        case .month: "30 days"
        case .forever: "Forever"
        }
    }
}
