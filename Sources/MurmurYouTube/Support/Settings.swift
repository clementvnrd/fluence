import Foundation
import Observation

/// Which speech engine transcribes an utterance.
enum SpeechEngineChoice: String, CaseIterable, Sendable {
    case apple
    case whisper
    case parakeet

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

/// Spoken language for speech recognition.
enum DictationLanguage: String, CaseIterable, Sendable {
    case french = "fr-FR"
    case english = "en-US"
    case auto = "auto"
    case system = "system"

    var displayName: String {
        switch self {
        case .french: "Français"
        case .english: "English"
        case .auto: "Auto (FR / EN)"
        case .system: "Système"
        }
    }

    var shortDisplay: String {
        switch self {
        case .french: "FR"
        case .english: "EN"
        case .auto: "AUTO"
        case .system: "SYS"
        }
    }

    /// Two-letter ISO language code for Whisper, or nil for automatic detection.
    var whisperLanguageCode: String? {
        switch self {
        case .french: return "fr"
        case .english: return "en"
        case .auto: return nil
        case .system:
            let lang = Locale.current.language.languageCode?.identifier ?? "fr"
            return lang.lowercased().starts(with: "en") ? "en" : "fr"
        }
    }

    var locale: Locale {
        switch self {
        case .french: Locale(identifier: "fr-FR")
        case .english: Locale(identifier: "en-US")
        case .auto: Locale(identifier: "fr-FR")
        case .system: Locale.current
        }
    }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    /// Target language for speech recognition.
    var language: DictationLanguage {
        didSet { defaults.set(language.rawValue, forKey: Keys.language) }
    }

    var pushToTalkKey: PushToTalkKey {
        didSet { defaults.set(pushToTalkKey.rawValue, forKey: Keys.pushToTalkKey) }
    }

    /// UID of selected microphone device, or "default" for macOS system default.
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
            if engine == .whisper {
                prewarmCurrentEngine()
            }
        }
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

    /// Whether to run Apple Intelligence LLM cleanup on Whisper transcripts.
    /// False by default because Whisper already emits clean punctuated text natively in < 0.8s,
    /// and running the LLM adds ~3.5s of redundant latency.
    var smartCleanupOnWhisper: Bool {
        didSet { defaults.set(smartCleanupOnWhisper, forKey: Keys.smartCleanupOnWhisper) }
    }

    /// Play a short tick when capture starts and stops.
    var soundEnabled: Bool {
        didSet { defaults.set(soundEnabled, forKey: Keys.soundEnabled) }
    }

    /// Automatically adapt formatting and punctuation to the active application.
    var appAwareStylesEnabled: Bool {
        didSet { defaults.set(appAwareStylesEnabled, forKey: Keys.appAwareStylesEnabled) }
    }

    /// Expand voice shortcuts into full snippets.
    var snippetsEnabled: Bool {
        didSet { defaults.set(snippetsEnabled, forKey: Keys.snippetsEnabled) }
    }

    /// Transform selected text using spoken instructions.
    var commandModeEnabled: Bool {
        didSet { defaults.set(commandModeEnabled, forKey: Keys.commandModeEnabled) }
    }

    /// Dedicated modifier key for triggering Command Mode.
    var commandModeKey: PushToTalkKey {
        didSet { defaults.set(commandModeKey.rawValue, forKey: Keys.commandModeKey) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let language = "language"
        static let pushToTalkKey = "pushToTalkKey"
        static let cleanupEnabled = "cleanupEnabled"
        static let soundEnabled = "soundEnabled"
        static let engine = "engine"
        static let whisperModel = "whisperModel"
        static let smartCleanup = "smartCleanup"
        static let smartCleanupOnWhisper = "smartCleanupOnWhisper"
        static let compareMode = "compareMode"
        static let appAwareStylesEnabled = "appAwareStylesEnabled"
        static let snippetsEnabled = "snippetsEnabled"
        static let commandModeEnabled = "commandModeEnabled"
        static let commandModeKey = "commandModeKey"
        static let selectedMicrophoneUID = "selectedMicrophoneUID"
    }

    private init() {
        let rawLang = defaults.string(forKey: Keys.language) ?? DictationLanguage.french.rawValue
        language = DictationLanguage(rawValue: rawLang) ?? .french

        let raw = defaults.string(forKey: Keys.pushToTalkKey) ?? PushToTalkKey.optionSpace.rawValue
        pushToTalkKey = PushToTalkKey(rawValue: raw) ?? .optionSpace

        selectedMicrophoneUID = defaults.string(forKey: Keys.selectedMicrophoneUID) ?? "default"

        let rawCmd = defaults.string(forKey: Keys.commandModeKey) ?? PushToTalkKey.commandOption.rawValue
        commandModeKey = PushToTalkKey(rawValue: rawCmd) ?? .commandOption

        // Apple by default: no download, no dependency, live text while speaking.
        engine = SpeechEngineChoice(rawValue: defaults.string(forKey: Keys.engine) ?? "") ?? .apple
        whisperModel = defaults.string(forKey: Keys.whisperModel) ?? WhisperModels.defaultVariant
        cleanupEnabled = defaults.object(forKey: Keys.cleanupEnabled) as? Bool ?? true
        smartCleanup = defaults.object(forKey: Keys.smartCleanup) as? Bool ?? true
        smartCleanupOnWhisper = defaults.object(forKey: Keys.smartCleanupOnWhisper) as? Bool ?? false
        compareMode = defaults.object(forKey: Keys.compareMode) as? Bool ?? false
        soundEnabled = defaults.object(forKey: Keys.soundEnabled) as? Bool ?? true
        appAwareStylesEnabled = defaults.object(forKey: Keys.appAwareStylesEnabled) as? Bool ?? true
        snippetsEnabled = defaults.object(forKey: Keys.snippetsEnabled) as? Bool ?? true
        commandModeEnabled = defaults.object(forKey: Keys.commandModeEnabled) as? Bool ?? true
    }

    /// Rapidly toggles language on the fly.
    func toggleLanguage() {
        if engine == .whisper {
            switch language {
            case .french: language = .english
            case .english: language = .auto
            case .auto: language = .french
            default: language = .french
            }
        } else {
            language = (language == .french) ? .english : .french
        }
        Task.detached(priority: .utility) {
            await AppleSpeechEngine.prewarm(locale: self.language.locale)
        }
    }

    /// Prewarms the currently selected speech engine in background so dictation starts instantly.
    func prewarmCurrentEngine() {
        switch engine {
        case .apple:
            let loc = language.locale
            Task.detached(priority: .utility) {
                await AppleSpeechEngine.prewarm(locale: loc)
            }
        case .whisper:
            let model = whisperModel
            Task.detached(priority: .userInitiated) {
                _ = try? await WhisperModels.shared.prepare(variant: model)
            }
        case .parakeet:
            Task.detached(priority: .userInitiated) {
                _ = try? await ParakeetModels.shared.manager()
            }
        }
    }
}
