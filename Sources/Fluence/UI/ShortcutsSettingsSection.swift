import SwiftUI

/// Réglages ▸ Raccourcis: every gesture of the shortcuts in one card, and the switch for
/// the last-transcript chords. The shortcuts themselves are chosen in the Général and
/// IA & Formatage tabs (Clement's recorder); this card describes what they do.
struct ShortcutsSettingsSection: View {
    @Bindable var controller: DictationController
    @State private var settings = Settings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            SettingsPanel(label: "Gestes") {
                ShortcutLegend()
                if !controller.hasEventTap {
                    SettingsNote("Échap, ⌃⌘V / ⌃⌘C et les raccourcis sans touche (⌃ ⌥) ont besoin de "
                        + "l'autorisation Accessibilité. Les raccourcis avec une touche (⌥ Espace) "
                        + "marchent sans elle.")
                }
            }

            SettingsPanel(label: "Dernière transcription") {
                Toggle(isOn: Binding(
                    get: { settings.lastTranscriptShortcuts },
                    set: { on in
                        settings.lastTranscriptShortcuts = on
                        controller.reloadHotkey()
                    }
                )) {
                    Text("⌃⌘V colle, ⌃⌘C copie la dernière transcription")
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.ink)
                }
                .toggleStyle(.switch)
                SettingsNote("Gardée en mémoire seulement, jusqu'à ce que vous quittiez. Désactivez-le si "
                    + "une autre app utilise ces touches.")
            }
        }
    }
}

/// The legend itself, also shown on the onboarding window's last page.
struct ShortcutLegend: View {
    @State private var settings = Settings.shared

    private var rows: [(keys: String, action: String)] {
        let key = settings.pushToTalkKey.shortName
        var rows: [(String, String)] = [
            ("Maintenir \(key)", "Dicter ; relâcher pour taper le texte"),
            ("Toucher \(key)", "Mains libres : enregistre jusqu'au prochain appui"),
        ]
        if settings.pushToTalkKey.isModifierOnly {
            rows.append(("\(key) + Espace", "Mains libres, depuis un maintien"))
        }
        rows.append(("Échap", "Annuler — rien n'est tapé"))
        if settings.commandModeEnabled {
            rows.append((settings.commandModeKey.shortName, "Mode Commande : dites comment modifier la sélection"))
        }
        rows.append(("⌥L", "Basculer la langue de dictée"))
        if settings.lastTranscriptShortcuts {
            rows.append(("⌃⌘V", "Coller la dernière transcription"))
            rows.append(("⌃⌘C", "Copier la dernière transcription"))
        }
        return rows
    }

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: DS.Space.roomy, verticalSpacing: DS.Space.snug) {
            ForEach(rows, id: \.keys) { row in
                GridRow {
                    Text(row.keys)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(DS.Color.accent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(DS.Color.well, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                    Text(row.action)
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.ink)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
