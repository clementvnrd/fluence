import FluenceCore
import Foundation
import FluenceDictionary

/// Moteur d'auto-apprentissage de Murmur / Fluence.
/// Analyse les corrections apportées par l'utilisateur pour enrichir automatiquement
/// le dictionnaire personnel et apprendre le vocabulaire de ses projets.
///
/// FLU-11, against main's protections: everything here stays in memory, nothing it reads
/// or learns is logged (counts only), and the silent learning of frequent terms runs only
/// when the user opted in (Settings ▸ IA & Formatage, `learnFrequentTerms`). Corrections
/// made in the *Corriger* sheet and a project scan are explicit actions and stay as they were.
@MainActor
public final class AutoLearningEngine {
    public static let shared = AutoLearningEngine()

    /// Dernier texte dicté et injecté, conservé pour détecter une correction immédiate.
    public private(set) var lastInjectedText: String = ""
    public private(set) var lastInjectedDate: Date?

    /// Mémorise les termes et noms propres fréquemment employés par l'utilisateur.
    private var frequentTerms: [String: Int] = [:]

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
        extractAndLearnTerms(from: text)
    }

    /// Extrait automatiquement les termes spécifiques (noms propres, acronymes, CamelCase, jargon technique)
    /// pour les mémoriser et renforcer l'attention de Whisper lors des futures dictées.
    private func extractAndLearnTerms(from text: String) {
        let words = text.components(separatedBy: CharacterSet.whitespacesAndNewlines)
        for (index, rawWord) in words.enumerated() {
            var word = rawWord.trimmingCharacters(in: CharacterSet.punctuationCharacters)
            // Supprime les élisions françaises courantes (ex: d'Apple -> Apple, l'IA -> IA)
            word = word.replacingOccurrences(of: "^[ldcjmtsnLDCMTSN]'|^qu'|^QU'", with: "", options: .regularExpression)
            guard word.count >= 2 else { continue }

            // Détecte les acronymes majuscules (ex: API, PR, LLM, CLI, AWS, PS5)
            let isAcronym = word.allSatisfy { $0.isUppercase || $0.isNumber } && word.count >= 2 && word.count <= 6 && word.contains(where: { $0.isUppercase })

            // Détecte les termes en CamelCase / PascalCase ou avec ponctuation interne (ex: SwiftUI, MacBook, Next.js, PostgreSQL)
            let hasInternalCaps = word.dropFirst().contains { $0.isUppercase }
            let hasInternalPunct = rawWord.contains(".") || rawWord.contains("-") || rawWord.contains("/")

            // Détecte les noms propres capitalisés au milieu d'une phrase (pas en début de phrase index 0)
            let isMidSentenceCapitalized = index > 0 && word.first?.isUppercase == true && !word.allSatisfy { $0.isUppercase }

            if isAcronym || hasInternalCaps || hasInternalPunct || isMidSentenceCapitalized {
                let candidate = (hasInternalPunct ? rawWord.trimmingCharacters(in: CharacterSet(charactersIn: ",;!?\"'()[]{}")) : word)
                guard candidate.count >= 2 else { continue }
                frequentTerms[candidate, default: 0] += 1

                // Dès qu'un terme spécialisé a été employé 2 fois, l'ajouter au dictionnaire
                if frequentTerms[candidate, default: 0] >= 2 {
                    let exists = DictionaryStore.shared.entries.contains {
                        $0.write.caseInsensitiveCompare(candidate) == .orderedSame
                    }
                    if !exists {
                        DictionaryStore.shared.add(.term(candidate))
                        Log.speech.info("AutoLearning: 1 terme ajouté au dictionnaire")
                    }
                }
            }
        }
    }

    // MARK: - Diff & Déduction des Corrections (hear -> write)

    public struct LearnedPair: Equatable, Sendable {
        public let hear: String
        public let write: String
    }

    /// Compare le texte original transcrit et le texte corrigé par l'utilisateur
    /// pour en extraire automatiquement les règles d'apprentissage.
    public func learnCorrection(from original: String, to corrected: String) -> [DictionaryEntry] {
        let trimmedOriginal = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCorrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedOriginal.isEmpty, !trimmedCorrected.isEmpty, trimmedOriginal != trimmedCorrected else {
            return []
        }

        let pairs = computeWordDiff(original: trimmedOriginal, corrected: trimmedCorrected)
        var addedEntries: [DictionaryEntry] = []

        for pair in pairs {
            let hear = pair.hear.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))
            let write = pair.write.trimmingCharacters(in: CharacterSet.punctuationCharacters.union(.whitespaces))

            guard !hear.isEmpty, !write.isEmpty, hear.caseInsensitiveCompare(write) != .orderedSame else {
                continue
            }

            // Ne pas écraser par un mot trop court de 1 lettre sauf si sigle capitalisé (ex: PR)
            if hear.count == 1 && !(write.count >= 2) {
                continue
            }

            let entry = DictionaryEntry.correction(hear: hear, write: write)

            // Vérifie que l'entrée n'existe pas déjà
            let exists = DictionaryStore.shared.entries.contains {
                $0.kind == .correction &&
                $0.hear.caseInsensitiveCompare(hear) == .orderedSame &&
                $0.write.caseInsensitiveCompare(write) == .orderedSame
            }

            if !exists {
                DictionaryStore.shared.add(entry)
                addedEntries.append(entry)

            }
        }

        if !addedEntries.isEmpty {
            Log.speech.info("AutoLearning: \(addedEntries.count, privacy: .public) correction(s) ajoutée(s)")
        }
        return addedEntries
    }

    /// Algorithme d'alignement mot-à-mot pour isoler les portions modifiées.
    private func computeWordDiff(original: String, corrected: String) -> [LearnedPair] {
        let origWords = tokenize(original)
        let corrWords = tokenize(corrected)

        guard !origWords.isEmpty, !corrWords.isEmpty else { return [] }

        // Utilise la plus longue sous-séquence commune (LCS) pour aligner les mots
        let lcsMatrix = computeLCSMatrix(origWords, corrWords)
        var i = origWords.count
        var j = corrWords.count

        var pairs: [LearnedPair] = []
        var diffOrig: [String] = []
        var diffCorr: [String] = []

        while i > 0 || j > 0 {
            if i > 0 && j > 0 && origWords[i - 1].caseInsensitiveCompare(corrWords[j - 1]) == .orderedSame {
                if !diffOrig.isEmpty || !diffCorr.isEmpty {
                    let h = diffOrig.reversed().joined(separator: " ")
                    let w = diffCorr.reversed().joined(separator: " ")
                    if !h.isEmpty && !w.isEmpty {
                        pairs.append(LearnedPair(hear: h, write: w))
                    }
                    diffOrig.removeAll()
                    diffCorr.removeAll()
                }
                i -= 1
                j -= 1
            } else if j > 0 && (i == 0 || lcsMatrix[i][j - 1] >= lcsMatrix[i - 1][j]) {
                diffCorr.append(corrWords[j - 1])
                j -= 1
            } else if i > 0 && (j == 0 || lcsMatrix[i][j - 1] < lcsMatrix[i - 1][j]) {
                diffOrig.append(origWords[i - 1])
                i -= 1
            }
        }

        if !diffOrig.isEmpty || !diffCorr.isEmpty {
            let h = diffOrig.reversed().joined(separator: " ")
            let w = diffCorr.reversed().joined(separator: " ")
            if !h.isEmpty && !w.isEmpty {
                pairs.append(LearnedPair(hear: h, write: w))
            }
        }

        return pairs
    }

    private func tokenize(_ text: String) -> [String] {
        text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
    }

    private func computeLCSMatrix(_ s1: [String], _ s2: [String]) -> [[Int]] {
        let m = s1.count
        let n = s2.count
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)

        for i in 1...m {
            for j in 1...n {
                if s1[i - 1].caseInsensitiveCompare(s2[j - 1]) == .orderedSame {
                    dp[i][j] = dp[i - 1][j - 1] + 1
                } else {
                    dp[i][j] = max(dp[i - 1][j], dp[i][j - 1])
                }
            }
        }
        return dp
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
