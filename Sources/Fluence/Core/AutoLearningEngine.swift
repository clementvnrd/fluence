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
/// A project scan is an explicit action and adds directly.
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

    // MARK: - Auto-Library & Workspace Scanner

    /// Scanne un dossier de projet (code source, documents) pour extraire les termes techniques
    /// et noms propres spécifiques au projet (ex: branches Git, dépendances, nom du projet).
    public func scanWorkspaceForVocabulary(at url: URL) async -> [String] {
        var terms = Set<String>()

        // 1. Nom du dossier racine
        let projectName = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !projectName.isEmpty && projectName.count > 2 {
            terms.insert(projectName)
        }

        // 2. Fichiers de configuration courants (package.json, Package.swift, Cargo.toml)
        let packageJsonURL = url.appendingPathComponent("package.json")
        if let data = try? Data(contentsOf: packageJsonURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let name = json["name"] as? String { terms.insert(name) }
            if let deps = json["dependencies"] as? [String: Any] {
                for key in deps.keys.prefix(20) {
                    let clean = key.replacingOccurrences(of: "@[^/]+/", with: "", options: .regularExpression)
                    terms.insert(clean)
                }
            }
        }

        // 3. Branches Git
        let gitHeadURL = url.appendingPathComponent(".git/HEAD")
        if let headContent = try? String(contentsOf: gitHeadURL, encoding: .utf8) {
            let branch = headContent.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "ref: refs/heads/", with: "")
            if !branch.isEmpty {
                terms.insert(branch)
            }
        }

        // Ajoute les termes découverts au dictionnaire personnel comme .term
        var addedCount = 0
        for term in terms where term.count >= 3 {
            let alreadyKnown = DictionaryStore.shared.entries.contains {
                $0.write.caseInsensitiveCompare(term) == .orderedSame
            }
            if !alreadyKnown {
                DictionaryStore.shared.add(.term(term))
                addedCount += 1
            }
        }

        if addedCount > 0 {
            Log.speech.info("AutoLearning: \(addedCount) termes découverts depuis l'espace de travail")
        }

        return Array(terms)
    }
}
