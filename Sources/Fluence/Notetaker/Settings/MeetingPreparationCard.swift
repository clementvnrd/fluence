import FluenceCore
import SwiftUI

/// Réglages ▸ Réunions, first card (FLU-45): what a first meeting would still ask or
/// download, and one button that does it now.
struct MeetingPreparationCard: View {
    @Bindable var preparation: MeetingPreparation

    private var state: MeetingReadiness.State { preparation.state }

    var body: some View {
        SectionCard {
            SettingsRow(
                systemImage: "checklist",
                title: "Préparer les réunions",
                subtitle: preparation.failure ?? (state.isReady ? "Prêt pour votre prochain appel" : "À faire avant votre premier appel"),
                info: "Demande les autorisations et télécharge les modèles maintenant, pour qu'aucune fenêtre de macOS "
                    + "ni aucune attente n'arrive pendant un appel. Les modèles viennent de Hugging Face, une seule fois ; "
                    + "aucun son ni aucun texte ne quitte ce Mac.",
                iconTint: preparation.failure == nil ? DS.Color.accent : DS.Color.destructive
            ) {
                HStack(spacing: DS.Space.snug) {
                    if preparation.isRunning { ProgressView().controlSize(.small) }
                    CapButton(
                        title: MeetingReadiness.actionTitle(state),
                        height: 24,
                        isEnabled: preparation.canRun
                    ) {
                        Task { await preparation.prepare() }
                    }
                }
            }
            RowDivider()
            grantRow("mic", "Micro", grant: state.microphone, settings: Permissions.openMicrophoneSettings)
            RowDivider()
            SettingsRow(
                systemImage: "speaker.wave.2",
                title: "Son des appels",
                info: "macOS ne dit pas si l'accès est accordé, seulement s'il a été demandé. Un refus se change dans Réglages Système."
            ) {
                HStack(spacing: DS.Space.snug) {
                    GrantBadge(text: MeetingReadiness.label(state.systemAudio), isOK: state.systemAudio == .asked)
                    CapButton(title: "Réglages…", height: 24) { Permissions.openSystemAudioSettings() }
                }
            }
            if let calendar = state.calendar {
                RowDivider()
                grantRow("calendar", "Calendrier", grant: calendar, settings: Permissions.openCalendarSettings)
            }
            RowDivider()
            SettingsRow(
                systemImage: "square.and.arrow.down",
                title: "Modèles",
                info: state.models.map { "\($0.name) (~\($0.megabytes)\(FrenchFormat.space)Mo)" }.joined(separator: ", ") + "."
            ) {
                HStack(spacing: DS.Space.snug) {
                    if let progress = preparation.downloadProgress {
                        ProgressView(value: progress).frame(width: 90)
                    }
                    GrantBadge(
                        text: MeetingReadiness.modelsLabel(state, progress: preparation.downloadProgress),
                        isOK: state.missingModels.isEmpty
                    )
                }
            }
        }
        .onAppear { preparation.refresh() }
    }

    /// A refusal can only be undone in System Settings, so it gets the button that opens it.
    private func grantRow(_ symbol: String, _ title: String, grant: MeetingReadiness.Grant, settings: @escaping () -> Void) -> some View {
        SettingsRow(systemImage: symbol, title: title) {
            HStack(spacing: DS.Space.snug) {
                GrantBadge(text: MeetingReadiness.label(grant), isOK: grant == .granted)
                if grant == .refused {
                    CapButton(title: "Réglages…", height: 24, action: settings)
                }
            }
        }
    }
}
