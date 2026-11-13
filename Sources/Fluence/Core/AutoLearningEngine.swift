import FluenceCore
import Foundation
import FluenceDictionary

/// Moteur d'auto-apprentissage de Murmur / Fluence.
/// Analyse les corrections apportées par l'utilisateur pour enrichir automatiquement
/// le dictionnaire personnel et apprendre le vocabulaire de ses projets.
///
/// FLU-11, against main's protections: everything here stays in memory, nothing it reads
/// or learns is logged (counts only), and frequent terms are counted only when the user opted
/// in (Settings ▸ IA & Formatage, `learnFrequentTerms`) and are then only proposed (FLU-88).
@MainActor
public final class AutoLearningEngine {
    public static let shared = AutoLearningEngine()

    /// Dernier texte dicté et injecté, conservé pour détecter une correction immédiate.
    public private(set) var lastInjectedText: String = ""
    public private(set) var lastInjectedDate: Date?

    /// Termes et noms propres comptés dans les dictées (FLU-88), en mémoire seulement.
    private var frequentTerms = FrequentTerms()

    /// Le contexte donné à Whisper avant la transcription : la fin de la dernière dictée si
    /// elle date de moins de 45 s, puis quelques termes du dictionnaire de l'utilisateur,
    /// en une phrase courte (`WhisperPrompt`).
    public func buildPromptContext() -> String? {
        // FLU-20: one short sentence, not a list of 35 terms (see `WhisperPrompt`).
        let recent = lastInjectedDate.map { Date().timeIntervalSince($0) < 45.0 } ?? false
        return WhisperPrompt.build(
            previous: recent ? lastInjectedText : nil,
            terms: DictionaryStore.shared.promptTerms,
            french: Settings.shared.dictationLanguage == .french
        )
    }

    /// Enregistre une dictée terminée pour le suivi d'apprentissage.
    public func recordInjectedText(_ text: String) {
        self.lastInjectedText = text
        self.lastInjectedDate = Date()
        guard Settings.shared.learnFrequentTerms else { return }
        // FLU-88: offered, never added — the silent `add` filled the dictionary with « prêt. », « Je »…
        let due = frequentTerms.record(text, at: Date())
        if !due.isEmpty { LearnedWords.shared.offer(due.map { EditLearner.Proposal(heard: $0, written: $0) }) }
    }
}
