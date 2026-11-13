import FluenceCore
import SwiftUI

/// Réglages ▸ Texte (FLU-12, mock-up 08): the styles per app, snippets, code formatting, and
/// the two ways the dictionary learns. The cleanup level is in Transcription (FLU-128).
struct TextSettingsSection: View {
    @State private var settings = Settings.shared
    @State private var snippets = SnippetStore.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        SectionCard {
            // The cards live on the Styles page; here, one row that leads there (FLU-19:
            // the same cards twice was the same text twice).
            SettingsRow(
                systemImage: "textformat",
                title: "Styles par app",
                subtitle: settings.stylesPause
            ) {
                CapButton(title: "Ouvrir", systemImage: "chevron.right", height: 28) {
                    MainNavigation.shared.show(.styles, openWindow: openWindow)
                }
            }
        }

        SectionCard {
            SettingsRow(
                systemImage: "text.badge.plus",
                title: "Snippets",
                subtitle: FrenchFormat.count(snippets.entries.count, "raccourci vocal", "raccourcis vocaux"),
                info: "Dites une courte phrase, Fluence écrit le texte complet : par exemple \(FrenchFormat.quoted("mon adresse")) → votre adresse."
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
                info: "Dans les éditeurs et les terminaux : symboles dictés, options de commande, pas de point final."
            ) {
                RowToggle(isOn: $settings.appAwareStylesEnabled)
            }
            RowDivider()
            SettingsRow(
                systemImage: "brain",
                title: "Apprentissage automatique",
                info: "Quand vous corrigez un nom juste après une dictée (par ex. \(FrenchFormat.quoted("Cubernetes")) → \(FrenchFormat.quoted("Kubernetes"))), Fluence vous propose de l'ajouter au dictionnaire. Vous acceptez ou ignorez, au cas par cas. Pendant 20 secondes, Fluence relit le champ ; rien de ce qui est lu n'est gardé, et les champs de mot de passe ne sont jamais lus."
            ) {
                RowToggle(isOn: $settings.learnFromEdits)
            }
            RowDivider()
            SettingsRow(
                systemImage: "text.append",
                title: "Apprendre les termes fréquents",
                info: "Un nom propre, un sigle ou un terme technique dicté trois fois, sur deux jours au moins, vous est proposé pour le dictionnaire. Le compte reste en mémoire et repart de zéro à chaque fermeture de Fluence."
            ) {
                RowToggle(isOn: $settings.learnFrequentTerms)
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
        case .medium: "Léger, puis le modèle sur votre Mac. En français, il corrige seulement les noms mal "
            + "entendus de votre dictionnaire ; dans les autres langues, il applique aussi vos auto-corrections."
        case .high: "En français, comme Moyen. Dans les autres langues, réécrit dans le style choisi pour l'app."
        }
    }
}
