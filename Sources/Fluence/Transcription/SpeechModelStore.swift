import FluenceCore
import FluidAudio
import Foundation
import Observation

/// The speech models on this Mac, for Réglages › Transcription (FLU-31): where each one lives,
/// what it weighs, and moving an unused one to the Trash when — and only when — the user
/// clicks *Supprimer* and confirms. Nothing here ever deletes on its own.
@MainActor
@Observable
final class SpeechModelStore {
    static let shared = SpeechModelStore()

    private(set) var installed: [InstalledSpeechModel] = []
    /// The last failed deletion, in French, until the next refresh.
    private(set) var failure: String?
    private var isRefreshing = false

    /// Where each model's folder is. FluidAudio's own cache paths, and the WhisperKit folder
    /// `WhisperModels` downloads into.
    nonisolated static func folder(for model: SpeechModel) -> URL {
        switch model {
        case .parakeetUltra: AsrModels.defaultCacheDirectory(for: .ultra)
        case .parakeetV3: AsrModels.defaultCacheDirectory(for: .v3)
        case .parakeetVocabulary: CtcModels.defaultCacheDirectory(for: .ctc110m)
        case .whisperBase, .whisperSmall, .whisperTurbo:
            WhisperModels.downloadDirectory
                .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
                .appendingPathComponent(model.whisperVariant ?? model.rawValue, isDirectory: true)
        }
    }

    private var settingsSnapshot: SpeechModelSettings {
        let settings = Settings.shared
        let engine: SpeechModelSettings.Engine = switch settings.engine {
        case .apple: .apple
        case .whisper: .whisper
        case .parakeet: .parakeet
        }
        return SpeechModelSettings(
            engine: engine,
            whisperVariant: settings.whisperModel,
            vocabularyBoost: settings.parakeetVocabularyBoost,
            compareMode: settings.compareMode
        )
    }

    /// Measures the folders off the main thread (3 GB of Whisper is thousands of files).
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let sizes = await Task.detached(priority: .utility) { Self.measure() }.value
        installed = SpeechModelInventory.installed(sizes: sizes, settings: settingsSnapshot)
    }

    /// The usage again, without measuring: after a setting changes.
    func reclassify() {
        let sizes = Dictionary(uniqueKeysWithValues: installed.map { ($0.model, $0.bytes) })
        installed = SpeechModelInventory.installed(sizes: sizes, settings: settingsSnapshot)
    }

    /// Moves the model's folder to the Trash. Refused for a model in use with the current
    /// settings, checked again here rather than trusted from the row that was clicked.
    func moveToTrash(_ model: SpeechModel) async {
        failure = nil
        guard model.usage(settingsSnapshot) == nil else {
            failure = "\(model.displayName) est utilisé : rien n'a été supprimé."
            return
        }
        let folder = Self.folder(for: model)
        do {
            try await Task.detached(priority: .userInitiated) {
                try FileManager.default.trashItem(at: folder, resultingItemURL: nil)
            }.value
            Log.app.info("speech model moved to the Trash: \(model.rawValue, privacy: .public)")
            if let variant = model.whisperVariant {
                await WhisperModels.shared.forget(variant: variant)
            }
        } catch {
            Log.app.error("speech model not moved to the Trash: \(model.rawValue, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            failure = "Suppression impossible : \(error.localizedDescription)"
        }
        await refresh()
    }

    // MARK: - Measuring

    private nonisolated static func measure() -> [SpeechModel: Int64] {
        var sizes: [SpeechModel: Int64] = [:]
        for model in SpeechModel.allCases {
            let folder = folder(for: model)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            sizes[model] = bytes(in: folder)
        }
        return sizes
    }

    /// What the folder takes on disk, as the Finder counts it.
    private nonisolated static func bytes(in folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
