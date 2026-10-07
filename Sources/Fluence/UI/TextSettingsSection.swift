import FluenceCore
import SwiftUI

/// Settings for what happens to the words (FLU-5 text): cleanup level, language, styles per
/// kind of app, and the dictionary's two helpers (Parakeet boosting, learning from edits).
struct TextSettingsSection: View {
    @State private var settings = Settings.shared
    @State private var boostStatus: BoostStatus = ParakeetModels.isVocabularyModelDownloaded ? .ready : .idle

    private enum BoostStatus: Equatable {
        case idle, downloading, ready
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.wide) {
            cleanupPanel
            languagePanel
            stylesPanel
            dictionaryPanel
        }
    }

    // MARK: Cleanup

    private var cleanupPanel: some View {
        SettingsPanel(label: "Niveau de nettoyage") {
            SelectorKeys(
                options: CleanupLevel.allCases,
                title: \.title,
                selection: settings.cleanupLevel
            ) { settings.cleanupLevel = $0 }
            SettingsNote(settings.cleanupLevel.explanation)
            if settings.cleanupLevel.usesModel, let reason = FoundationModelFormatter.unavailableReason {
                SettingsNote("\(reason) En attendant, ce niveau nettoie avec les règles du niveau Léger.")
            }
            SettingsNote("Les corrections du dictionnaire et vos snippets s'appliquent à tous les niveaux.")
            if settings.engine == .whisper, !settings.smartCleanupOnWhisper, settings.cleanupLevel.usesModel {
                SettingsNote("Avec Whisper, le modèle n'est utilisé que si « Post-traitement LLM sur Whisper » "
                    + "est activé (onglet IA & Formatage) ; sinon ce niveau nettoie avec les règles.")
            }
        }
    }

    // MARK: Language

    private static let quickLanguages: [DictationLanguage] = [.auto, .english, .french]

    private var languagePanel: some View {
        SettingsPanel(label: "Langue de dictée") {
            HStack(spacing: DS.Space.snug) {
                SelectorKeys(
                    options: Self.quickLanguages,
                    title: \.displayName,
                    selection: Self.quickLanguages.contains(settings.dictationLanguage) ? settings.dictationLanguage : nil
                ) { settings.dictationLanguage = $0 }
                otherLanguages
            }
            SettingsNote(languageNote)
        }
    }

    /// The other 23 languages behind one key, so the row stays a row.
    private var otherLanguages: some View {
        let isOther = !Self.quickLanguages.contains(settings.dictationLanguage)
        return Menu {
            ForEach(DictationLanguage.spoken.filter { !Self.quickLanguages.contains($0) }, id: \.self) { language in
                Button(language.displayName) { settings.dictationLanguage = language }
            }
        } label: {
            Silkscreen(text: isOther ? settings.dictationLanguage.displayName : "Autre…", color: DS.Color.ink)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Space.base)
        .frame(height: DS.Material.keyHeight)
        .background {
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .fill(isOther ? DS.Color.selection : DS.Color.cap)
        }
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.control)
                .strokeBorder(DS.Color.selectionEdge, lineWidth: DS.Border.hairline)
        )
        .fixedSize()
    }

    private var languageNote: String {
        switch settings.dictationLanguage {
        case .auto:
            "Apple écoute dans la langue de votre Mac ; Whisper et Parakeet détectent la langue eux-mêmes. "
                + "Le nettoyage reconnaît la langue de chaque dictée."
        case .english, .french:
            "Les moteurs et le nettoyage attendent : \(settings.dictationLanguage.displayName)."
        default:
            "Les moteurs attendent : \(settings.dictationLanguage.displayName). Le nettoyage corrige les espaces "
                + "et les majuscules ; les hésitations et la ponctuation dictée ne sont connues qu'en anglais et en français."
        }
    }

    // MARK: Styles

    private var stylesPanel: some View {
        SettingsPanel(label: "Style par application") {
            ForEach(AppCategory.allCases, id: \.self) { category in
                HStack(spacing: DS.Space.base) {
                    Silkscreen(text: category.displayName)
                        .frame(width: DS.Parity.categoryColumn, alignment: .leading)
                    SelectorKeys(
                        options: WritingStyle.allCases,
                        title: \.displayName,
                        selection: settings.style(for: category)
                    ) { settings.styles[category] = $0 }
                }
            }
            SettingsNote(settings.cleanupLevel == .high
                ? "Choisi d'après l'app où vous dictez — Messages, Slack, Mail… — et, dans un navigateur, "
                    + "d'après la page (Gmail, Slack, WhatsApp Web). L'adresse de la page est lue une fois et jamais gardée."
                : "Les styles ne s'appliquent qu'au niveau Élevé.")
        }
    }

    // MARK: Dictionary helpers

    private var dictionaryPanel: some View {
        SettingsPanel(label: "Dictionnaire") {
            Toggle(isOn: $settings.learnFromEdits) {
                Silkscreen(text: "Apprendre de mes corrections")
            }
            .toggleStyle(.switch)
            SettingsNote("Désactivé tant que vous ne l'activez pas. Pendant 20 secondes après la saisie, Fluence "
                + "relit le champ ; si vous corrigez un nom qu'il a écrit, il propose de l'ajouter au "
                + "dictionnaire. Rien n'est ajouté sans vous, rien de ce qui est lu n'est gardé, et les "
                + "champs de mot de passe ne sont jamais lus.")

            Toggle(isOn: $settings.learnFrequentTerms) {
                Silkscreen(text: "Apprendre les termes fréquents")
            }
            .toggleStyle(.switch)
            SettingsNote("Désactivé par défaut. Activé, un nom propre, un sigle ou un terme technique dicté "
                + "deux fois est ajouté au dictionnaire sans vous le demander.")

            Toggle(isOn: Binding(get: { settings.parakeetVocabularyBoost }, set: setBoost)) {
                Silkscreen(text: "Renforcer les mots du dictionnaire dans Parakeet")
            }
            .toggleStyle(.switch)
            SettingsNote(boostNote)
        }
    }

    private var boostNote: String {
        let what = "Un second petit modèle repère les mots de votre dictionnaire et corrige la transcription "
            + "de Parakeet quand il en entend un. Téléchargement unique d'environ 100 Mo ; réglé pour l'anglais."
        switch boostStatus {
        case .idle: return what
        case .downloading: return "Téléchargement du modèle (~100 Mo)…"
        case .ready: return what + " Modèle installé."
        case .failed(let message): return "Échec du téléchargement : \(message). Désactivez puis réactivez pour réessayer."
        }
    }

    private func setBoost(_ enabled: Bool) {
        settings.parakeetVocabularyBoost = enabled
        guard enabled, boostStatus != .downloading else { return }
        boostStatus = .downloading
        Task {
            do {
                _ = try await ParakeetModels.shared.loadVocabularyModel()
                boostStatus = .ready
            } catch {
                boostStatus = .failed(error.localizedDescription)
            }
        }
    }
}

extension CleanupLevel {
    var title: String {
        switch self {
        case .none: "Aucun"
        case .light: "Léger"
        case .medium: "Moyen"
        case .high: "Élevé"
        }
    }

    var explanation: String {
        switch self {
        case .none: "Ce que le moteur a entendu, tel quel."
        case .light: "Retire les hésitations, bégaiements et répétitions, transforme la ponctuation dictée, "
            + "corrige espaces et majuscules. Instantané."
        case .medium: "Léger, puis le modèle sur votre Mac : applique vos auto-corrections (« 17 h, non, 18 h »), "
            + "met en forme les listes, écrit les nombres en chiffres."
        case .high: "Moyen, puis réécrit dans le style choisi pour le type d'app où vous écrivez."
        }
    }
}
