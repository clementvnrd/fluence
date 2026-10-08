import FluenceCore
import FluenceNotesCore
import SwiftUI

/// The Meetings part of Settings: actions that need a confirmation first.
@MainActor
@Observable
final class MeetingSettingsModel {
    static let shared = MeetingSettingsModel()

    let settings: NotetakerSettings
    let store: MeetingStore

    /// A shorter retention that would delete meetings right away, awaiting confirmation.
    var pendingRetention: RetentionChoice?
    var pendingRetentionCount = 0
    var isConfirmingRetention = false
    var isConfirmingVoicePrintsOff = false
    var isConfirmingDeleteAll = false
    /// Short-lived "Copié !" on the consent keys.
    private(set) var flash: String?

    @ObservationIgnored private var flashTask: Task<Void, Never>?

    init(settings: NotetakerSettings = .shared, store: MeetingStore = .shared) {
        self.settings = settings
        self.store = store
    }

    // MARK: Retention

    var retention: RetentionChoice? { RetentionChoice(days: settings.retentionDays) }

    /// Applies at once when nothing would be deleted; otherwise asks first, saying how many.
    func chooseRetention(_ choice: RetentionChoice) {
        let count = Retention.expiredCount(store.summaries.map(\.startedAt), days: choice.days, now: Date())
        if count > 0 {
            pendingRetention = choice
            pendingRetentionCount = count
            isConfirmingRetention = true
        } else {
            applyRetention(choice)
        }
    }

    func applyRetention(_ choice: RetentionChoice) {
        settings.retentionDays = choice.days
        pendingRetention = nil
        NotetakerNotes.purgeExpired()
    }

    // MARK: Voice prints

    /// On takes effect at once. Off deletes every print, so it is confirmed first.
    func setVoicePrints(_ enabled: Bool) {
        if enabled {
            settings.voicePrintsEnabled = true
        } else if settings.voicePrintsEnabled {
            isConfirmingVoicePrintsOff = true
        }
    }

    func turnVoicePrintsOff() {
        settings.voicePrintsEnabled = false
        NotetakerHooks.voicePrintsDisabled()
    }

    // MARK: Delete all

    func deleteAllMeetings() {
        MeetingNotesGenerator.shared.cancelAll()
        store.deleteAll()
        NotesTemplateChoice.prune(keeping: [])
        MeetingLibraryModel.shared.reconcile()
    }

    // MARK: Feedback

    func showFlash(_ text: String) {
        flash = text
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: DS.Library.flashDuration)
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }
}

/// Réglages ▸ Réunions (FLU-12): detection, speaker names, consent. Keeping audio,
/// retention and voice prints are in Confidentialité, beside what they protect.
struct MeetingSettingsSection: View {
    @Bindable var model: MeetingSettingsModel
    @State private var hasCalendar = Permissions.hasCalendar

    private var settings: NotetakerSettings { model.settings }

    var body: some View {
        SectionCard {
            SettingsRow(
                systemImage: "person.2.wave.2",
                title: "Détecter les réunions",
                info: "Repère les appels — Zoom, Teams, Meet ou un navigateur — et propose de prendre des notes. Rien n'est enregistré sans votre clic sur Enregistrer ; un point rouge reste visible tant que l'enregistrement dure."
            ) {
                RowToggle(isOn: Bindable(settings).detectMeetings)
            }
            RowDivider()
            SettingsRow(
                systemImage: "timer",
                title: "Enregistrer sans clic",
                info: settings.autoRecordSeconds == 0
                    ? "Jamais : la carte attend votre clic. Si vous ne répondez pas, rien n'est enregistré."
                    : "Si vous ne répondez pas à la carte, l'enregistrement démarre seul après \(settings.autoRecordSeconds)\(FrenchFormat.space)s. Prévenez les participants."
            ) {
                PillTabs(
                    options: DetectionOffer.autoRecordChoices,
                    title: { $0 == 0 ? "Jamais" : "\($0)\(FrenchFormat.space)s" },
                    selection: settings.autoRecordSeconds,
                    small: true
                ) { settings.autoRecordSeconds = $0 }
            }
            RowDivider()
            SettingsRow(systemImage: "stop.circle", title: "Arrêter après", info: "Un enregistrement s'arrête de lui-même au bout de cette durée.") {
                PillTabs(
                    options: Self.maxDurations,
                    title: { "\($0 / 60)\(FrenchFormat.space)h" },
                    selection: settings.maxDurationMinutes,
                    small: true
                ) { settings.maxDurationMinutes = $0 }
            }
        }

        SectionCard {
            SettingsRow(
                systemImage: "person.text.rectangle",
                title: "Lire les noms dans la fenêtre de l'appel",
                info: "Les noms affichés par Zoom, Teams et Meet, lus via l'Accessibilité, pour dire qui a parlé."
            ) {
                RowToggle(isOn: Bindable(settings).readNamesFromMeetingWindow)
            }
            RowDivider()
            SettingsRow(
                systemImage: "calendar",
                title: "Utiliser mon calendrier",
                info: "Le titre de la réunion et ses invités, et la liste « À venir »."
            ) {
                HStack(spacing: DS.Space.snug) {
                    if settings.useCalendar && !hasCalendar {
                        CapButton(title: "Autoriser…", height: 24) {
                            if Permissions.calendarUndecided {
                                Task {
                                    _ = await Permissions.requestCalendar()
                                    hasCalendar = Permissions.hasCalendar
                                }
                            } else {
                                Permissions.openCalendarSettings()
                            }
                        }
                    }
                    RowToggle(isOn: Bindable(settings).useCalendar)
                }
            }
        }

        SectionCard {
            SettingsRow(
                systemImage: "text.bubble",
                title: "Consentement",
                subtitle: "Prévenez les participants avant d'enregistrer",
                info: "Enregistrer des personnes sans les prévenir est illégal dans de nombreux pays, dont la France. Copiez cet avis et collez-le dans le chat de la réunion avant de commencer : \(FrenchFormat.quoted(NotetakerConsent.text(.french)))"
            ) {
                ConsentKeys(flash: model.flash) { model.showFlash($0) }
            }
        }

        SectionCard {
            SettingsRow(
                systemImage: "trash",
                title: "Supprimer toutes les réunions",
                subtitle: Self.storedNote(model.store.summaries.count),
                iconTint: DS.Color.destructive
            ) {
                DestructiveButton(title: "Supprimer…", isEnabled: !model.store.summaries.isEmpty) {
                    model.isConfirmingDeleteAll = true
                }
            }
        }
        .onAppear { hasCalendar = Permissions.hasCalendar }
        .confirmationDialog(
            "Supprimer toutes les réunions (\(model.store.summaries.count)) ?",
            isPresented: $model.isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Supprimer toutes les réunions", role: .destructive) { model.deleteAllMeetings() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Chaque transcription, chaque ensemble de notes et chaque enregistrement conservé est effacé avec sa clé "
                + "de chiffrement. Cette action est irréversible.")
        }
    }

    private static let maxDurations = [60, 120, 180, 240]

    private static func storedNote(_ count: Int) -> String {
        count > 1
            ? "\(count) réunions stockées, chiffrées sur ce Mac"
            : "\(count) réunion stockée, chiffrée sur ce Mac"
    }
}

extension RetentionChoice {
    /// French names of the presets: `RetentionChoice.title` lives in FluenceNotesCore.
    var settingsTitle: String {
        switch self {
        case .forever: "Toujours"
        case .week: "7 jours"
        case .month: "30 jours"
        case .quarter: "90 jours"
        case .year: "1 an"
        }
    }

    /// "pendant 30 jours" / "pour toujours", after "Conserver les réunions".
    var phrase: String { self == .forever ? "pour toujours" : "pendant " + settingsTitle }
}
