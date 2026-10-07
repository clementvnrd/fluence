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

/// Settings → Meetings. Bound to `NotetakerSettings`; every switch explains, in plain
/// words, what it changes.
struct MeetingSettingsSection: View {
    @Bindable var model: MeetingSettingsModel

    private var settings: NotetakerSettings { model.settings }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.wide) {
            detectionPanel
            namesPanel
            storagePanel
            consentPanel
        }
        .confirmationDialog(
            "Conserver les réunions \(model.pendingRetention.map(Self.retentionPhrase) ?? "") ?",
            isPresented: $model.isConfirmingRetention,
            titleVisibility: .visible,
            presenting: model.pendingRetention
        ) { choice in
            Button(Self.deleteOlderTitle(model.pendingRetentionCount), role: .destructive) {
                model.applyRetention(choice)
            }
            Button("Annuler", role: .cancel) { model.pendingRetention = nil }
        } message: { _ in
            Text(Self.deleteOlderMessage(model.pendingRetentionCount))
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

    // MARK: Panels

    private var detectionPanel: some View {
        SettingsPanel(label: "Réunions") {
            Toggle(isOn: Bindable(settings).detectMeetings) {
                toggleLabel("Détecter les réunions")
            }
            .toggleStyle(.switch)
            SettingsNote("Repère les appels — le micro utilisé par Zoom, Teams, Meet ou un navigateur — "
                + "et propose de prendre des notes. Fluence n'enregistre jamais sans l'afficher.")

            LabeledFact(label: "Compte à rebours avant l'enregistrement") {
                SelectorKeys(
                    options: Self.countdowns,
                    title: { $0 == 0 ? "Aucun" : "\($0) s" },
                    selection: settings.countdownSeconds
                ) { settings.countdownSeconds = $0 }
            }
            SettingsNote(settings.countdownSeconds == 0
                ? "La carte « Réunion détectée » attend que vous appuyiez sur Enregistrer."
                : "La carte « Réunion détectée » lance l'enregistrement après \(settings.countdownSeconds) secondes, "
                    + "sauf si vous choisissez « Pas maintenant ».")

            LabeledFact(label: "Arrêter après") {
                SelectorKeys(
                    options: Self.maxDurations,
                    title: { "\($0 / 60) h" },
                    selection: settings.maxDurationMinutes
                ) { settings.maxDurationMinutes = $0 }
            }
            SettingsNote("Un enregistrement s'arrête de lui-même au bout de cette durée, quoi qu'il arrive.")
        }
    }

    private var namesPanel: some View {
        SettingsPanel(label: "Noms des intervenants") {
            Toggle(isOn: Bindable(settings).readNamesFromMeetingWindow) {
                toggleLabel("Lire les noms dans la fenêtre de la réunion")
            }
            .toggleStyle(.switch)
            SettingsNote("Lit les noms affichés par Zoom, Teams et Meet, via l'Accessibilité, pour indiquer qui a parlé.")

            Toggle(isOn: Bindable(settings).useCalendar) {
                toggleLabel("Utiliser mon calendrier")
            }
            .toggleStyle(.switch)
            SettingsNote("Reprend le titre de la réunion et la liste des participants depuis votre calendrier.")

            Toggle(isOn: Binding(get: { settings.voicePrintsEnabled }, set: { model.setVoicePrints($0) })) {
                toggleLabel("Reconnaître les voix (empreintes vocales)")
            }
            .toggleStyle(.switch)
            SettingsNote("Désactivé tant que vous ne l'activez pas. Une fois activé, Fluence conserve une empreinte "
                + "vocale — une série de nombres qui décrit la voix d'une personne que vous avez nommée — pour la "
                + "reconnaître lors des réunions suivantes. Une empreinte vocale est une donnée biométrique : elle "
                + "identifie quelqu'un à partir de son corps, la loi la protège donc plus strictement. Les empreintes "
                + "restent sur ce Mac, ne sont jamais exportées, et désactiver cette option les supprime toutes.")
        }
    }

    private var storagePanel: some View {
        SettingsPanel(label: "Stockage") {
            Toggle(isOn: Bindable(settings).keepAudioByDefault) {
                toggleLabel("Conserver l'audio des réunions")
            }
            .toggleStyle(.switch)
            SettingsNote("Désactivé : l'enregistrement est supprimé dès que la transcription est finalisée ; seules "
                + "la transcription et les notes chiffrées sont conservées. Vous pouvez toujours garder l'audio "
                + "d'une réunion pendant son enregistrement.")

            LabeledFact(label: "Conserver les réunions") {
                SelectorKeys(
                    options: RetentionChoice.allCases,
                    title: \.settingsTitle,
                    selection: model.retention
                ) { model.chooseRetention($0) }
            }
            SettingsNote(model.retention == nil
                ? "Actuellement \(settings.retentionDays ?? 0) jours. Les réunions plus anciennes sont supprimées au démarrage de Fluence."
                : "Les réunions plus anciennes sont supprimées au démarrage de Fluence et quand vous modifiez ce réglage.")

            HStack(spacing: DS.Space.base) {
                TransportKey(
                    title: "Supprimer toutes les réunions",
                    systemImage: "trash",
                    isEnabled: !model.store.summaries.isEmpty
                ) {
                    model.isConfirmingDeleteAll = true
                }
                SettingsNote(Self.storedNote(model.store.summaries.count))
            }
        }
    }

    private var consentPanel: some View {
        SettingsPanel(label: "Consentement") {
            SettingsNote("Enregistrer des personnes sans les prévenir est illégal dans de nombreux pays, dont la France. "
                + "Copiez cet avis et collez-le dans le chat de la réunion avant de commencer :")
            Text(NotetakerConsent.text(.french))
                .font(DS.Font.label)
                .italic()
                .foregroundStyle(DS.Color.ink)
                .fixedSize(horizontal: false, vertical: true)
            ConsentKeys(flash: model.flash) { model.showFlash($0) }
        }
    }

    private static let countdowns = [0, 5, 10, 20, 30, 60]
    private static let maxDurations = [60, 120, 180, 240]

    // MARK: Wording

    /// A switch's label, in the cards' body ink.
    private func toggleLabel(_ text: String) -> some View {
        Text(text)
            .font(DS.Font.label)
            .foregroundStyle(DS.Color.ink)
    }

    /// "pendant 7 jours" / "pour toujours", after "Conserver les réunions".
    private static func retentionPhrase(_ choice: RetentionChoice) -> String {
        choice == .forever ? "pour toujours" : "pendant " + choice.settingsTitle
    }

    private static func deleteOlderTitle(_ count: Int) -> String {
        count > 1
            ? "Supprimer les \(count) réunions plus anciennes"
            : "Supprimer la réunion plus ancienne"
    }

    private static func deleteOlderMessage(_ count: Int) -> String {
        count > 1
            ? "\(count) réunions sont plus anciennes et seront supprimées maintenant, avec leurs notes et "
                + "transcriptions. Cette action est irréversible."
            : "1 réunion est plus ancienne et sera supprimée maintenant, avec ses notes et sa transcription. "
                + "Cette action est irréversible."
    }

    private static func storedNote(_ count: Int) -> String {
        count > 1
            ? "\(count) réunions stockées, chiffrées sur ce Mac."
            : "\(count) réunion stockée, chiffrée sur ce Mac."
    }
}

/// French names of the retention presets, for this section only: `RetentionChoice.title`
/// lives in FluenceNotesCore and is left as it is.
fileprivate extension RetentionChoice {
    var settingsTitle: String {
        switch self {
        case .forever: "Toujours"
        case .week: "7 jours"
        case .month: "30 jours"
        case .quarter: "90 jours"
        case .year: "1 an"
        }
    }
}

/// A labelled card, as in the rest of Settings.
struct SettingsPanel<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Silkscreen(text: label, large: true)
            content
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BrushedPanel())
    }
}

struct SettingsNote: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(DS.Font.label)
            .foregroundStyle(DS.Color.inkSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
