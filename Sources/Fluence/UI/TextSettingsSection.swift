import FluenceCore
import SwiftUI

/// Réglages ▸ Texte (FLU-12, mock-up 08): the cleanup level with one sentence shown at every
/// level, the styles per app, snippets, code formatting, and the two ways the dictionary
/// learns.
struct TextSettingsSection: View {
    @State private var settings = Settings.shared
    @State private var snippets = SnippetStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SectionCard {
            SettingsRow(systemImage: "sparkles", title: "Niveau de nettoyage", subtitle: "Exemple pour la même phrase dictée :") {
                PillTabs(options: CleanupLevel.allCases, title: \.title, selection: settings.cleanupLevel, small: true) {
                    settings.cleanupLevel = $0
                }
            }
            CleanupExamples(selection: settings.cleanupLevel) { settings.cleanupLevel = $0 }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            RowNote(text: cleanupNote)
        }

        SectionCard {
            SettingsRow(systemImage: "textformat", title: "Styles par app", subtitle: "Le ton s'adapte à l'app où vous dictez.") {
                Text(WritingStyle.allCases.map(\.displayName).joined(separator: " · "))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.silkscreen)
            }
            StyleTiles()
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            if settings.cleanupLevel != .high {
                RowNote(text: "Les styles ne s'appliquent qu'au niveau Élevé.")
            }
        }

        SectionCard {
            SettingsRow(
                systemImage: "text.badge.plus",
                title: "Snippets",
                subtitle: FrenchFormat.count(snippets.entries.count, "raccourci vocal", "raccourcis vocaux")
                    + " · ex. \(FrenchFormat.quoted("mon adresse")) → votre adresse complète"
            ) {
                HStack(spacing: DS.Space.snug) {
                    CapButton(title: "Gérer les snippets", systemImage: "chevron.right", height: 28) {
                        MainNavigation.shared.show(.snippets, openWindow: openWindow)
                    }
                    RowToggle(isOn: $settings.snippetsEnabled)
                }
            }
            RowDivider()
            SettingsRow(
                systemImage: "chevron.left.forwardslash.chevron.right",
                title: "Formatage code & terminaux",
                subtitle: "Dans les éditeurs et les terminaux : symboles dictés, options de commande, pas de point final."
            ) {
                RowToggle(isOn: $settings.appAwareStylesEnabled)
            }
            RowDivider()
            SettingsRow(
                systemImage: "brain",
                title: "Apprentissage automatique",
                subtitle: settings.learnFromEdits ? "Activé · rien n'est ajouté sans votre accord" : "Désactivé · rien n'est ajouté sans votre accord"
            ) {
                RowToggle(isOn: $settings.learnFromEdits)
            }
            RowNote(text: "Quand vous corrigez un nom juste après une dictée (par ex. \(FrenchFormat.quoted("Cubernetes")) → \(FrenchFormat.quoted("Kubernetes"))), Fluence vous propose de l'ajouter au dictionnaire. Vous acceptez ou ignorez, au cas par cas. Pendant 20 secondes, Fluence relit le champ ; rien de ce qui est lu n'est gardé, et les champs de mot de passe ne sont jamais lus.")
            RowDivider()
            SettingsRow(
                systemImage: "text.append",
                title: "Apprendre les termes fréquents",
                subtitle: settings.learnFrequentTerms ? "Activé" : "Désactivé"
            ) {
                RowToggle(isOn: $settings.learnFrequentTerms)
            }
            RowNote(text: "Un nom propre, un sigle ou un terme technique dicté deux fois est ajouté au dictionnaire sans vous le demander.")
        }
    }

    private var cleanupNote: String {
        var note = settings.cleanupLevel.explanation + " Les corrections du dictionnaire et vos snippets s'appliquent à tous les niveaux."
        if settings.cleanupLevel.usesModel, let reason = FoundationModelFormatter.unavailableReason {
            note += " \(reason) En attendant, ce niveau nettoie avec les règles du niveau Léger."
        } else if settings.engine == .whisper, !settings.smartCleanupOnWhisper, settings.cleanupLevel.usesModel {
            note += " Avec Whisper, le modèle n'est utilisé que si « Nettoyage par le modèle avec Whisper » est activé (Transcription) ; sinon ce niveau nettoie avec les règles."
        }
        return note
    }
}

/// The same sentence at the four levels; the chosen one highlighted, any one clickable.
private struct CleanupExamples: View {
    let selection: CleanupLevel
    let onSelect: (CleanupLevel) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(CleanupLevel.allCases, id: \.self) { level in
                let isSelected = level == selection
                Button { onSelect(level) } label: {
                    HStack(spacing: DS.Space.base) {
                        Text(level.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(isSelected ? DS.Color.accent : DS.Color.inkSecondary)
                            .frame(width: 46, alignment: .leading)
                        Text(FrenchFormat.quoted(level.example))
                            .font(DS.Font.body)
                            .foregroundStyle(isSelected ? DS.Color.ink : DS.Color.inkSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if isSelected {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DS.Color.accent)
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Color.selection)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .background(DS.Color.well, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
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

    /// One dictated sentence at this level (mock-up 08) — an illustration, not a promise.
    var example: String {
        switch self {
        case .none: "euh donc on se voit jeudi, enfin non, vendredi vers 14\u{00A0}h quoi"
        case .light: "Donc on se voit jeudi, enfin non, vendredi vers 14\u{00A0}h."
        case .medium: "On se voit vendredi vers 14\u{00A0}h."
        case .high: "Rendez-vous vendredi à 14\u{00A0}h."
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
