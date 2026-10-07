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

    // MARK: FLU-5 text

    /// How much cleanup runs between the engine and the text field. Replaces the old
    /// `cleanupEnabled` / `smartCleanup` switches, which are migrated once (see `init`).
    var cleanupLevel: CleanupLevel {
        didSet { defaults.set(cleanupLevel.rawValue, forKey: Keys.cleanupLevel) }
    }

    /// The language dictated in. Auto keeps the system locale for Apple's engine, lets
    /// Parakeet detect, and has cleanup detect each transcript's language.
    var dictationLanguage: DictationLanguage {
        didSet { defaults.set(dictationLanguage.rawValue, forKey: Keys.dictationLanguage) }
    }

    /// The writing style per kind of app, applied at cleanup level High only.
    var styles: [AppCategory: WritingStyle] {
        didSet {
            for (category, style) in styles {
                defaults.set(style.rawValue, forKey: Keys.style(category))
            }
        }
    }

    func style(for category: AppCategory) -> WritingStyle {
        styles[category] ?? category.defaultStyle
    }

    /// Parakeet only: rescore its transcript against the dictionary with FluidAudio's CTC
    /// keyword spotter. Opt-in because it downloads a second model (~100 MB) and costs a
    /// second encoder pass per dictation.
    var parakeetVocabularyBoost: Bool {
        didSet { defaults.set(parakeetVocabularyBoost, forKey: Keys.parakeetVocabularyBoost) }
    }

    /// Re-read the text field after typing and offer, never add, words the user corrected.
    /// Off by default: it reads what is in the field around the dictation for 20 seconds.
    var learnFromEdits: Bool {
        didSet { defaults.set(learnFromEdits, forKey: Keys.learnFromEdits) }
    }

    // MARK: end FLU-5 text

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

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        /// Legacy (before FLU-5): read once by the cleanup-level migration, never written.
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        /// Legacy (before FLU-5), as above.
        static let smartCleanup = "smartCleanup"
        static let compareMode = "compareMode"
        static let historyRetention = "historyRetention"
        static let maxRecordingMinutes = "maxRecordingMinutes"
        // MARK: FLU-5 text
        static let cleanupLevel = "cleanupLevel"
        static let dictationLanguage = "dictationLanguage"
        static let parakeetVocabularyBoost = "parakeetVocabularyBoost"
        static let learnFromEdits = "learnFromEdits"
        static func style(_ category: AppCategory) -> String { "style.\(category.rawValue)" }
    }

    private init() {
        // Before the first read: settings chosen under the app's previous name carry over.
        LegacyMigration.migrateDefaults(into: defaults)
        let raw = defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.rightOption.rawValue
        pushToTalkKey = PushToTalkKey(rawValue: raw) ?? .rightOption
        // Apple by default: no download, no dependency, live text while speaking.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        // MARK: FLU-5 text
        // The level is stored as soon as it is first derived, so the migration from the two
        // old switches runs exactly once and a later change to them can't override it. The
        // old keys are left in place: a downgraded build still finds what it expects.
        if let level = CleanupLevel(rawValue: defaults.string(forKey: Keys.cleanupLevel) ?? "") {
            cleanupLevel = level
        } else {
            cleanupLevel = CleanupLevel.migrated(
                cleanupEnabled: defaults.object(forKey: Keys.cleanupEnabled) as? Bool,
                smartCleanup: defaults.object(forKey: Keys.smartCleanup) as? Bool
            )
            defaults.set(cleanupLevel.rawValue, forKey: Keys.cleanupLevel)
        }
        dictationLanguage = DictationLanguage(rawValue: defaults.string(forKey: Keys.dictationLanguage) ?? "") ?? .auto
        var styles: [AppCategory: WritingStyle] = [:]
        for category in AppCategory.allCases {
            styles[category] = WritingStyle(rawValue: defaults.string(forKey: Keys.style(category)) ?? "")
                ?? category.defaultStyle
        }
        self.styles = styles
        parakeetVocabularyBoost = defaults.object(forKey: Keys.parakeetVocabularyBoost) as? Bool ?? false
        learnFromEdits = defaults.object(forKey: Keys.learnFromEdits) as? Bool ?? false
        // MARK: end FLU-5 text
        compareMode = defaults.object(forKey: Keys.compareMode) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        historyRetention = HistoryRetention(rawValue: defaults.string(forKey: Keys.historyRetention) ?? "")
            ?? .default
        let limit = defaults.integer(forKey: Keys.maxRecordingMinutes)
        maxRecordingMinutes = limit > 0 ? limit : 10
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
