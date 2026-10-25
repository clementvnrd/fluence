import Foundation

/// The speech models Fluence can find on disk, which of them the app still uses, and what
/// they weigh (FLU-31: Réglages › Transcription lists them, and offers *Supprimer* for the
/// ones nothing uses). Where each one lives is the app's business; this is the rule.
public enum SpeechModel: String, CaseIterable, Sendable, Identifiable {
    case parakeetUltra
    /// The Parakeet the app used before Ultra (FLU-24). Nothing in the app loads it any more;
    /// only the French bench compares against it.
    case parakeetV3
    /// The small CTC model behind vocabulary boosting.
    case parakeetVocabulary
    case whisperBase
    case whisperSmall
    case whisperTurbo

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .parakeetUltra: "Parakeet Ultra"
        case .parakeetV3: "Parakeet v3"
        case .parakeetVocabulary: "Parakeet · vocabulaire"
        case .whisperBase: "Whisper Base"
        case .whisperSmall: "Whisper Small"
        case .whisperTurbo: "Whisper Large Turbo"
        }
    }

    /// WhisperKit's name for the model, for the Whisper ones.
    public var whisperVariant: String? {
        switch self {
        case .whisperBase: "openai_whisper-base"
        case .whisperSmall: "openai_whisper-small"
        case .whisperTurbo: "openai_whisper-large-v3_turbo"
        default: nil
        }
    }

    public static func whisper(variant: String) -> SpeechModel? {
        allCases.first { $0.whisperVariant == variant }
    }

    /// What a download weighs on disk, measured on an M2 (FLU-31) where known: the label
    /// shown before the model is downloaded. Whisper Large Turbo was announced as "~1,5 Go"
    /// and takes 3,2 Go.
    public var typicalBytes: Int64 {
        switch self {
        case .parakeetUltra: 632_000_000
        case .parakeetV3: 483_000_000
        case .parakeetVocabulary: 100_000_000  // FluidAudio's figure, not measured
        case .whisperBase: 140_000_000         // the previous label, not measured
        case .whisperSmall: 487_000_000
        case .whisperTurbo: 3_195_000_000
        }
    }

    /// "Whisper Large Turbo (~3,2 Go)", for the model picker.
    public var pickerTitle: String {
        "\(displayName) (~\(FrenchFormat.bytes(typicalBytes)))"
    }

    /// Why the app needs this model with these settings, or nil when nothing does.
    public func usage(_ settings: SpeechModelSettings) -> SpeechModelUsage? {
        switch self {
        case .parakeetUltra:
            // Meetings always transcribe with Parakeet Ultra, whatever the dictation engine.
            settings.engine == .parakeet || settings.compareMode ? .dictation : .meetings
        case .parakeetV3:
            nil
        case .parakeetVocabulary:
            settings.vocabularyBoost ? .vocabulary : nil
        case .whisperBase, .whisperSmall, .whisperTurbo:
            settings.engine == .whisper && settings.whisperVariant == whisperVariant ? .dictation : nil
        }
    }
}

public enum SpeechModelUsage: Equatable, Sendable {
    case dictation
    case meetings
    case vocabulary
}

/// The settings that decide which models are in use, read from the app's `Settings`.
public struct SpeechModelSettings: Equatable, Sendable {
    public enum Engine: Sendable { case apple, whisper, parakeet }

    public var engine: Engine
    public var whisperVariant: String
    public var vocabularyBoost: Bool
    public var compareMode: Bool

    public init(engine: Engine, whisperVariant: String, vocabularyBoost: Bool, compareMode: Bool = false) {
        self.engine = engine
        self.whisperVariant = whisperVariant
        self.vocabularyBoost = vocabularyBoost
        self.compareMode = compareMode
    }
}

/// One model found on disk, as Réglages shows it.
public struct InstalledSpeechModel: Equatable, Sendable, Identifiable {
    public let model: SpeechModel
    public let bytes: Int64
    public let usage: SpeechModelUsage?

    public var id: SpeechModel { model }

    /// Only a model nothing uses may be deleted, and only by the user's click.
    public var canDelete: Bool { usage == nil }

    /// "3,2 Go" or "632 Mo · utilisé".
    public var subtitle: String {
        let size = FrenchFormat.bytes(bytes)
        return usage == nil ? size : "\(size) · utilisé"
    }
}

public enum SpeechModelInventory {
    /// The models found on disk with their sizes: the ones in use first, then the heaviest.
    /// - Parameter sizes: bytes on disk per model present; absent models are left out.
    public static func installed(sizes: [SpeechModel: Int64], settings: SpeechModelSettings) -> [InstalledSpeechModel] {
        sizes
            .map { InstalledSpeechModel(model: $0.key, bytes: max(0, $0.value), usage: $0.key.usage(settings)) }
            .sorted { lhs, rhs in
                if (lhs.usage == nil) != (rhs.usage == nil) { return lhs.usage != nil }
                if lhs.bytes != rhs.bytes { return lhs.bytes > rhs.bytes }
                return lhs.model.rawValue < rhs.model.rawValue
            }
    }

    /// What the models nothing uses take on disk.
    public static func reclaimableBytes(_ models: [InstalledSpeechModel]) -> Int64 {
        models.filter(\.canDelete).reduce(0) { $0 + $1.bytes }
    }

    public static func totalBytes(_ models: [InstalledSpeechModel]) -> Int64 {
        models.reduce(0) { $0 + $1.bytes }
    }
}
