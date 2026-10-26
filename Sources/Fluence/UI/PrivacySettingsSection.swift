import FluenceCore
import FluenceNotesCore
import SwiftUI

/// Réglages ▸ Confidentialité (FLU-12, mock-up 09): what Fluence keeps, for how long, the
/// voice prints, the permissions, and *Tout effacer*.
struct PrivacySettingsSection: View {
    @Bindable var controller: DictationController
    @Bindable var model: MeetingSettingsModel
    @State private var settings = Settings.shared
    @State private var runs = RunStore.shared
    @State private var hasAccessibility = Permissions.hasAccessibility
    @State private var hasMicrophone = Permissions.hasMicrophone
    @State private var isConfirmingEraseAll = false
    @State private var safety = DataSafetyModel.shared

    private var notetaker: NotetakerSettings { model.settings }

    /// 30 jours / 1 an / Toujours, plus the stored value when it is another preset (7 or 90
    /// days, from before FLU-12), so it stays visible and selected rather than lost.
    private var meetingChoices: [RetentionChoice] {
        var choices: [RetentionChoice] = [.month, .year, .forever]
        if let current = model.retention, !choices.contains(current) {
            choices.insert(current, at: 0)
        }
        return choices
    }

    var body: some View {
        if safety.isKeyLost {
            KeyLostCard(model: safety)
        }

        summaryCard

        SectionCard {
            SettingsRow(
                systemImage: "clock.arrow.circlepath",
                title: "Historique des dictées",
                info: settings.historyRetention == .never ? "Rien n'est écrit sur le disque." : "Les dictées plus anciennes sont effacées automatiquement."
            ) {
                PillTabs(options: HistoryRetention.allCases, title: \.displayName, selection: settings.historyRetention, small: true) {
                    settings.historyRetention = $0
                    RunLog.applyRetention()
                }
            }
            if let problem = runs.problem {
                RowNote(text: problem, color: DS.Color.faultText)
            }
            RowDivider()
            SettingsRow(systemImage: "person.2", title: "Réunions et notes", subtitle: retentionSubtitle, info: "Notes, résumés et transcriptions : effacés automatiquement au-delà.") {
                PillTabs(options: meetingChoices, title: \.settingsTitle, selection: model.retention, small: true) {
                    model.chooseRetention($0)
                }
            }
            RowDivider()
            SettingsRow(
                systemImage: "waveform",
                title: "Garder l'audio des réunions par défaut",
                info: "Sinon l'audio est effacé dès que la transcription est prête. Modifiable pour chaque réunion."
            ) {
                RowToggle(isOn: Bindable(notetaker).keepAudioByDefault)
            }
        }

        SectionCard {
            SettingsRow(
                systemImage: "person.wave.2",
                title: "Empreintes vocales",
                subtitle: "Donnée biométrique · prévenez les personnes concernées",
                info: "Pour reconnaître vos interlocuteurs d'une réunion à l'autre, Fluence peut mémoriser la signature de leur voix. C'est une donnée biométrique : elle n'est créée que si vous l'activez, reste sur ce Mac, et s'efface ici à tout moment. Prévenez les personnes concernées."
            ) {
                RowToggle(isOn: Binding(get: { notetaker.voicePrintsEnabled }, set: { model.setVoicePrints($0) }))
            }
        }

        SectionCard {
            SettingsRow(systemImage: "mic.fill", title: "Micro") {
                if hasMicrophone {
                    GrantBadge(text: "Autorisé", isOK: true)
                } else {
                    CapButton(title: "Autoriser…", height: 24) { Permissions.openMicrophoneSettings() }
                }
            }
            RowDivider()
            SettingsRow(systemImage: "accessibility", title: "Accessibilité", info: "Pour repérer le raccourci et écrire là où est le curseur.") {
                if hasAccessibility {
                    GrantBadge(text: "Autorisé", isOK: true)
                } else {
                    CapButton(title: "Autoriser…", height: 24) {
                        Permissions.promptForAccessibility()
                        Permissions.openAccessibilitySettings()
                    }
                }
            }
            RowDivider()
            SettingsRow(systemImage: "bolt.fill", title: "Raccourcis") {
                GrantBadge(text: controller.isHotkeyActive ? "Actifs" : "Inactifs", isOK: controller.isHotkeyActive)
            }
            RowDivider()
            SettingsRow(
                systemImage: "arrow.counterclockwise",
                title: "Réinitialiser l'autorisation Accessibilité",
                info: "Si macOS affiche l'interrupteur activé sans l'appliquer."
            ) {
                CapButton(title: "Réinitialiser", height: 24) {
                    Permissions.resetAccessibilityTCC()
                    hasAccessibility = Permissions.hasAccessibility
                }
            }
        }

        BackupCard(model: safety)

        SectionCard {
            SettingsRow(
                systemImage: "trash",
                title: "Tout effacer",
                subtitle: "Dictées, réunions, notes, audio et empreintes · irréversible",
                iconTint: DS.Color.destructive
            ) {
                DestructiveButton(title: "Tout effacer…") { isConfirmingEraseAll = true }
            }
        }
        .onAppear {
            hasAccessibility = Permissions.hasAccessibility
            hasMicrophone = Permissions.hasMicrophone
            safety.refresh()
        }
        .confirmationDialog(
            "Tout effacer ?",
            isPresented: $isConfirmingEraseAll,
            titleVisibility: .visible
        ) {
            Button("Tout effacer", role: .destructive) { eraseAll() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("L'historique des dictées, chaque réunion avec ses notes, sa transcription et son audio, et toutes les "
                + "empreintes vocales sont supprimés de ce Mac. Le dictionnaire, les snippets et les réglages sont gardés. "
                + "Cette action est irréversible.")
        }
        .confirmationDialog(
            "Conserver les réunions \(model.pendingRetention?.phrase ?? "") ?",
            isPresented: $model.isConfirmingRetention,
            titleVisibility: .visible,
            presenting: model.pendingRetention
        ) { choice in
            Button(model.pendingRetentionCount > 1
                ? "Supprimer les \(model.pendingRetentionCount) réunions plus anciennes"
                : "Supprimer la réunion plus ancienne", role: .destructive) {
                model.applyRetention(choice)
            }
            Button("Annuler", role: .cancel) { model.pendingRetention = nil }
        } message: { _ in
            Text(model.pendingRetentionCount > 1
                ? "\(model.pendingRetentionCount) réunions sont plus anciennes et seront supprimées maintenant, avec leurs notes et transcriptions. Cette action est irréversible."
                : "1 réunion est plus ancienne et sera supprimée maintenant, avec ses notes et sa transcription. Cette action est irréversible.")
        }
        .confirmationDialog(
            "Désactiver les empreintes vocales ?",
            isPresented: $model.isConfirmingVoicePrintsOff,
            titleVisibility: .visible
        ) {
            Button("Désactiver et supprimer les empreintes vocales", role: .destructive) { model.turnVoicePrintsOff() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Toutes les empreintes vocales enregistrées sont supprimées. Les noms déjà présents dans vos réunions sont conservés.")
        }
    }

    private var summaryCard: some View {
        HStack(alignment: .top, spacing: DS.Space.roomy) {
            Image(systemName: "lock.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DS.Color.accent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(DS.Color.selection))
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("Tout reste sur ce Mac").font(DS.Font.title).foregroundStyle(DS.Color.ink)
                    InfoButton(text: "Vos dictées, réunions et notes sont transcrites et résumées sur cet ordinateur, puis enregistrées chiffrées. Rien n'est envoyé sur Internet, et il n'y a pas de compte.")
                }
                HStack(spacing: 6) {
                    MetaChip(text: "Transcription sur l'appareil", systemImage: "cpu")
                    MetaChip(text: "Chiffré sur le disque", systemImage: "lock.fill")
                    MetaChip(text: "Aucun envoi réseau", systemImage: "wifi.slash")
                }
                .padding(.top, 4)
            }
        }
        .padding(DS.Space.wide)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                .fill(DS.Color.panel)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous).strokeBorder(DS.Color.selectionEdge.opacity(0.6), lineWidth: 1))
                .shadow(color: DS.Shadow.raised.color, radius: DS.Shadow.raised.radius, y: DS.Shadow.raised.y)
        )
    }

    /// Only when the stored value is not one of the presets: then the pills show none selected.
    private var retentionSubtitle: String? {
        model.retention == nil ? "Actuellement \(notetaker.retentionDays ?? 0) jours" : nil
    }

    /// Dictations, meetings (notes, transcripts, audio) and voice prints. Not the
    /// dictionary, the snippets or the settings: those are things the user made, not records.
    private func eraseAll() {
        RunLog.clear()
        model.deleteAllMeetings()
        VoicePrintStore.shared.deleteAll()
    }
}
