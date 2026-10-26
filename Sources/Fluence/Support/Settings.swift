import FluenceCore
import Foundation
import Observation

/// Raw values are what the defaults store: renaming a case loses the user's choice.
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case whisper
    case parakeet

    /// The name shown in menus; history rows store it as their `engine`.
    var displayName: String {
        switch self {
        case .apple: "Apple (streaming)"
        case .whisper: "Whisper (CoreML)"
        case .parakeet: "Parakeet (batch)"
        }
    }

    /// Apple shows text while you talk; Whisper and Parakeet resolve on release.
    var showsLiveText: Bool { self == .apple }
}

// MARK: - Language (Clement's quick switch over FluenceCore's languages)

extension DictationLanguage {
    /// The pill on the HUD and the menu: FR, EN, AUTO…
    var shortDisplay: String {
        self == .auto ? "AUTO" : rawValue.uppercased()
    }

    /// Two-letter ISO code for Whisper, or nil for its own language detection.
    var whisperLanguageCode: String? { code }

    /// The locale Apple's transcriber is asked for.
    var locale: Locale { Locale(identifier: appleLocaleIdentifier(current: .current)) }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    /// The push-to-talk shortcut.
    var pushToTalkKey: PushToTalkKey {
        didSet { defaults.set(pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey) }
    }

    /// UID of the selected microphone, or "default" for the macOS system input.
    var selectedMicrophoneUID: String {
        didSet { defaults.set(selectedMicrophoneUID, forKey: Keys.selectedMicrophoneUID) }
    }

    var engine: SpeechEngineChoice {
        didSet {
            defaults.set(engine.rawValue, forKey: Keys.engine)
            prewarmCurrentEngine()
        }
    }

    /// Model variant used by WhisperKit (e.g. openai_whisper-small).
    var whisperModel: String {
        didSet {
            defaults.set(whisperModel, forKey: Keys.whisperModel)
            if engine == .whisper { prewarmCurrentEngine() }
        }
    }

    /// Every engine transcribes each recording and the results go to the comparison window;
    /// the focused app receives nothing.
    var compareMode: Bool {
        didSet { defaults.set(compareMode, forKey: Keys.compareMode) }
    }

    // MARK: FLU-5 text

    /// How much cleanup runs between the engine and the text field. Replaces the old
    /// `cleanupEnabled` / `smartCleanup` switches, which are migrated once (see `init`) and
    /// survive as views onto the level (below) for the settings window's two toggles.
    var cleanupLevel: CleanupLevel {
        didSet { defaults.set(cleanupLevel.rawValue, forKey: Keys.cleanupLevel) }
    }

    /// The language dictated in. Auto keeps the system locale for Apple's engine, lets
    /// Parakeet and Whisper detect, and has cleanup detect each transcript's language.
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

    // MARK: Clement's switches

    /// Whisper already writes punctuated, capitalised text; the on-device model on top adds
    /// ~3.5 s. Off by default: with Whisper, the model levels clean up with the rules only.
    var smartCleanupOnWhisper: Bool {
        didSet { defaults.set(smartCleanupOnWhisper, forKey: Keys.smartCleanupOnWhisper) }
    }

    /// Code and terminal formatting in developer tools: spoken symbols ("accolade ouvrante"),
    /// CLI flags, no trailing full stop on a one-line command.
    var appAwareStylesEnabled: Bool {
        didSet { defaults.set(appAwareStylesEnabled, forKey: Keys.appAwareStylesEnabled) }
    }

    /// Expand voice snippets.
    var snippetsEnabled: Bool {
        didSet { defaults.set(snippetsEnabled, forKey: Keys.snippetsEnabled) }
    }

    /// Command Mode: a second shortcut whose dictation is an instruction applied to the
    /// selected text instead of text to type.
    var commandModeEnabled: Bool {
        didSet { defaults.set(commandModeEnabled, forKey: Keys.commandModeEnabled) }
    }

    /// The Command Mode shortcut.
    var commandModeKey: PushToTalkKey {
        didSet { defaults.set(commandModeKey.rawValue, forKey: Keys.commandModeKey) }
    }

    /// Add names, acronyms and technical terms to the dictionary once they've been dictated
    /// twice. Off by default (opt-in): it changes the dictionary without asking each time.
    var learnFrequentTerms: Bool {
        didSet { defaults.set(learnFrequentTerms, forKey: Keys.learnFrequentTerms) }
    }

    // MARK: end Clement's switches

    /// "Tink" as the mic opens and on ⌥L, "Pop" when text lands, "Glass" after a comparison.
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

    /// ⌃⌘V pastes and ⌃⌘C copies the last transcript. Switchable because the chords are
    /// global: someone whose editor already uses them needs a way to give them back.
    var lastTranscriptShortcuts: Bool {
        didSet { defaults.set(lastTranscriptShortcuts, forKey: Keys.lastTranscriptShortcuts) }
    }

    // MARK: end FLU-5 input

    /// `.standard`, or the self-test's scratch settings (FLU-35).
    private let defaults = AppPaths.defaults

    enum Keys {
        static let pushToTalkKey = "pushToTalkKey"
        /// Legacy (before FLU-5): read once by the cleanup-level migration, never written.
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        static let whisperModel = "whisperModel"
        /// Legacy (before FLU-5), as above.
        static let smartCleanup = "smartCleanup"
        static let compareMode = "compareMode"
        static let historyRetention = "historyRetention"
        static let maxRecordingMinutes = "maxRecordingMinutes"
        static let selectedMicrophoneUID = "selectedMicrophoneUID"
        // MARK: FLU-5 input
        static let lastTranscriptShortcuts = "lastTranscriptShortcuts"
        // MARK: FLU-5 text
        static let cleanupLevel = "cleanupLevel"
        static let dictationLanguage = "dictationLanguage"
        /// Clement's build stored the language here, as "fr-FR", "en-US", "auto" or "system".
        static let legacyLanguage = "language"
        static let parakeetVocabularyBoost = "parakeetVocabularyBoost"
        static let learnFromEdits = "learnFromEdits"
        static func style(_ category: AppCategory) -> String { "style.\(category.rawValue)" }
        // Clement's switches
        static let smartCleanupOnWhisper = "smartCleanupOnWhisper"
        static let appAwareStylesEnabled = "appAwareStylesEnabled"
        static let snippetsEnabled = "snippetsEnabled"
        static let commandModeEnabled = "commandModeEnabled"
        static let commandModeKey = "commandModeKey"
        static let learnFrequentTerms = "learnFrequentTerms"
    }

    private init() {
        // Before the first read: settings chosen under the app's previous identity carry over.
        LegacyMigration.migrateDefaults(into: defaults)

        let raw = defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.optionSpace.rawValue
        pushToTalkKey = PushToTalkKey(rawValue: raw) ?? .optionSpace
        selectedMicrophoneUID = defaults.string(forKey: Keys.selectedMicrophoneUID) ?? "default"
        // Apple by default: it comes with macOS, downloads nothing and shows text live.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        whisperModel = defaults.string(forKey: Keys.whisperModel) ?? WhisperModels.defaultVariant

        // MARK: FLU-5 text
        // The level is stored as soon as it is first derived, so the migration from the two
        // old switches runs exactly once and a later change to them can't override it. The
        // old keys are left in place: a downgraded build still finds what it expects.
        if let level = CleanupLevel(rawValue: defaults.string(forKey: Keys.cleanupLevel) ?? "") {
            cleanupLevel = level
        } else {
            // Through a local: reading the @Observable property back would touch `self`
            // before every stored property is set.
            let migrated = CleanupLevel.migrated(
                cleanupEnabled: defaults.object(forKey: Keys.cleanupEnabled) as? Bool,
                smartCleanup: defaults.object(forKey: Keys.smartCleanup) as? Bool
            )
            cleanupLevel = migrated
            defaults.set(migrated.rawValue, forKey: Keys.cleanupLevel)
        }
        // French by default, as in Clement's build; his own "language" value is read once if
        // nothing is stored under the new key yet.
        if let stored = DictationLanguage(rawValue: defaults.string(forKey: Keys.dictationLanguage) ?? "") {
            dictationLanguage = stored
        } else {
            let migrated = LegacyMerge.dictationLanguage(fromLegacy: defaults.string(forKey: Keys.legacyLanguage))
                ?? .french
            dictationLanguage = migrated
            defaults.set(migrated.rawValue, forKey: Keys.dictationLanguage)
        }
        var styles: [AppCategory: WritingStyle] = [:]
        for category in AppCategory.allCases {
            styles[category] = WritingStyle(rawValue: defaults.string(forKey: Keys.style(category)) ?? "")
                ?? category.defaultStyle
        }
        self.styles = styles
        parakeetVocabularyBoost = defaults.object(forKey: Keys.parakeetVocabularyBoost) as? Bool ?? false
        learnFromEdits = defaults.object(forKey: Keys.learnFromEdits) as? Bool ?? false
        // MARK: end FLU-5 text

        smartCleanupOnWhisper = defaults.object(forKey: Keys.smartCleanupOnWhisper) as? Bool ?? false
        appAwareStylesEnabled = defaults.object(forKey: Keys.appAwareStylesEnabled) as? Bool ?? true
        snippetsEnabled = defaults.object(forKey: Keys.snippetsEnabled) as? Bool ?? true
        commandModeEnabled = defaults.object(forKey: Keys.commandModeEnabled) as? Bool ?? true
        let rawCommand = defaults.string(forKey: Keys.commandModeKey) ?? PushToTalkKey.commandOption.rawValue
        commandModeKey = PushToTalkKey(rawValue: rawCommand) ?? .commandOption
        learnFrequentTerms = defaults.object(forKey: Keys.learnFrequentTerms) as? Bool ?? false

        compareMode = defaults.object(forKey: Keys.compareMode) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        historyRetention = HistoryRetention(rawValue: defaults.string(forKey: Keys.historyRetention) ?? "")
            ?? .default
        // Bounded (R13): `limit * 60` trapped on a huge stored value, at every launch.
        maxRecordingMinutes = StoredSettings.recordingLimit(defaults.integer(forKey: Keys.maxRecordingMinutes))
        // MARK: FLU-5 input
        lastTranscriptShortcuts = defaults.object(forKey: Keys.lastTranscriptShortcuts) as? Bool ?? true
    }

    // MARK: - Clement's cleanup toggles, as views onto the level

    /// "Suppression des bégaiements & répétitions": any cleanup at all.
    var cleanupEnabled: Bool {
        get { cleanupLevel != .none }
        set {
            if !newValue {
                cleanupLevel = .none
            } else if cleanupLevel == .none {
                cleanupLevel = .light
            }
        }
    }

    /// "Nettoyage IA local": the on-device model runs (Medium, or High with styles).
    var smartCleanup: Bool {
        get { cleanupLevel.usesModel }
        set {
            if newValue {
                if !cleanupLevel.usesModel { cleanupLevel = .medium }
            } else if cleanupLevel.usesModel {
                cleanupLevel = .light
            }
        }
    }

    /// The level that actually runs for the current engine: with Whisper the model passes
    /// are skipped unless asked for, since Whisper's own output is already punctuated.
    var effectiveCleanupLevel: CleanupLevel {
        if engine == .whisper, !smartCleanupOnWhisper, cleanupLevel.usesModel { return .light }
        return cleanupLevel
    }

    /// Quick language switch (⌥L, the HUD pill): Français ⇄ English, plus Auto with Whisper,
    /// which detects the language itself.
    func toggleLanguage() {
        if engine == .whisper {
            dictationLanguage = switch dictationLanguage {
            case .french: .english
            case .english: .auto
            default: .french
            }
        } else {
            dictationLanguage = dictationLanguage == .french ? .english : .french
        }
        if engine == .apple {
            let locale = dictationLanguage.locale
            Task.detached(priority: .utility) {
                await AppleSpeechEngine.prewarm(locale: locale)
            }
        }
    }

    /// Prewarms the selected engine in the background so the first hold starts instantly.
    func prewarmCurrentEngine() {
        switch engine {
        case .apple:
            let locale = dictationLanguage.locale
            Task.detached(priority: .utility) {
                await AppleSpeechEngine.prewarm(locale: locale)
            }
        case .whisper:
            // Only a model already on disk: choosing Whisper must not start a download
            // nobody asked for. The settings and the menu offer that explicitly.
            let model = whisperModel
            guard WhisperModels.isDownloaded(variant: model) else { return }
            Task.detached(priority: .utility) {
                try? await WhisperModels.shared.prepare(variant: model)
            }
        case .parakeet:
            guard ParakeetModels.isDownloaded else { return }
            Task.detached(priority: .utility) {
                _ = try? await ParakeetModels.shared.manager()
            }
        }
    }
}

extension HistoryRetention {
    var displayName: String {
        switch self {
        case .never: "Ne pas garder"
        case .day: "1 jour"
        case .month: "30 jours"
        case .forever: "Toujours"
        }
    }
}
