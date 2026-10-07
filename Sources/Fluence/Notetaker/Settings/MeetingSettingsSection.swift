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
    /// Short-lived "Copied" on the consent keys.
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
            "Keep meetings for \(model.pendingRetention?.title.lowercased() ?? "")?",
            isPresented: $model.isConfirmingRetention,
            titleVisibility: .visible,
            presenting: model.pendingRetention
        ) { choice in
            Button("Delete \(model.pendingRetentionCount) Older Meeting\(model.pendingRetentionCount == 1 ? "" : "s")", role: .destructive) {
                model.applyRetention(choice)
            }
            Button("Cancel", role: .cancel) { model.pendingRetention = nil }
        } message: { _ in
            Text("\(model.pendingRetentionCount) meeting\(model.pendingRetentionCount == 1 ? " is" : "s are") older "
                + "than that and will be deleted now, with their notes and transcripts. This can't be undone.")
        }
        .confirmationDialog(
            "Turn off voice prints?",
            isPresented: $model.isConfirmingVoicePrintsOff,
            titleVisibility: .visible
        ) {
            Button("Turn Off and Delete Voice Prints", role: .destructive) { model.turnVoicePrintsOff() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every saved voice print is deleted. Names already in your meetings stay.")
        }
        .confirmationDialog(
            "Delete all \(model.store.summaries.count) meetings?",
            isPresented: $model.isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Delete All Meetings", role: .destructive) { model.deleteAllMeetings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every transcript, set of notes and kept recording is erased with its encryption key. This can't be undone.")
        }
    }

    // MARK: Panels

    private var detectionPanel: some View {
        SettingsPanel(label: "Meetings") {
            Toggle(isOn: Bindable(settings).detectMeetings) {
                Silkscreen(text: "Detect meetings")
            }
            .toggleStyle(.switch)
            SettingsNote("Watches for calls — the microphone in use by Zoom, Teams, Meet or a browser — "
                + "and offers to take notes. Fluence never records without showing it.")

            LabeledFact(label: "Countdown before recording") {
                SelectorKeys(
                    options: Self.countdowns,
                    title: { $0 == 0 ? "Off" : "\($0) s" },
                    selection: settings.countdownSeconds
                ) { settings.countdownSeconds = $0 }
            }
            SettingsNote(settings.countdownSeconds == 0
                ? "The Meeting detected card waits for you to press Start."
                : "The Meeting detected card starts recording after \(settings.countdownSeconds) seconds unless you cancel.")

            LabeledFact(label: "Stop after") {
                SelectorKeys(
                    options: Self.maxDurations,
                    title: { "\($0 / 60) h" },
                    selection: settings.maxDurationMinutes
                ) { settings.maxDurationMinutes = $0 }
            }
            SettingsNote("A recording stops on its own after this long, whatever happens.")
        }
    }

    private var namesPanel: some View {
        SettingsPanel(label: "Speaker names") {
            Toggle(isOn: Bindable(settings).readNamesFromMeetingWindow) {
                Silkscreen(text: "Read names from the meeting window")
            }
            .toggleStyle(.switch)
            SettingsNote("Reads the names Zoom, Teams and Meet display, through Accessibility, to label who spoke.")

            Toggle(isOn: Bindable(settings).useCalendar) {
                Silkscreen(text: "Use my calendar")
            }
            .toggleStyle(.switch)
            SettingsNote("Takes the meeting title and the list of attendees from your calendar.")

            Toggle(isOn: Binding(get: { settings.voicePrintsEnabled }, set: { model.setVoicePrints($0) })) {
                Silkscreen(text: "Recognise voices (voice prints)")
            }
            .toggleStyle(.switch)
            SettingsNote("Off unless you turn it on. When on, Fluence keeps a voice print — a set of numbers "
                + "describing how a person you named sounds — to recognise them in later meetings. A voice "
                + "print is biometric data: it identifies someone from their body, so the law protects it "
                + "more strictly. Prints stay on this Mac, are never exported, and turning this off deletes "
                + "all of them.")
        }
    }

    private var storagePanel: some View {
        SettingsPanel(label: "Storage") {
            Toggle(isOn: Bindable(settings).keepAudioByDefault) {
                Silkscreen(text: "Keep meeting audio")
            }
            .toggleStyle(.switch)
            SettingsNote("Off: the recording is deleted once the transcript is final; only the encrypted "
                + "transcript and notes are kept. You can still keep one meeting's audio while recording it.")

            LabeledFact(label: "Keep meetings for") {
                SelectorKeys(
                    options: RetentionChoice.allCases,
                    title: \.title,
                    selection: model.retention
                ) { model.chooseRetention($0) }
            }
            SettingsNote(model.retention == nil
                ? "Currently \(settings.retentionDays ?? 0) days. Older meetings are deleted when Fluence starts."
                : "Older meetings are deleted when Fluence starts and when you change this.")

            HStack(spacing: DS.Space.base) {
                TransportKey(
                    title: "Delete all meetings",
                    systemImage: "trash",
                    isEnabled: !model.store.summaries.isEmpty
                ) {
                    model.isConfirmingDeleteAll = true
                }
                SettingsNote("\(model.store.summaries.count) stored, encrypted on this Mac.")
            }
        }
    }

    private var consentPanel: some View {
        SettingsPanel(label: "Consent") {
            SettingsNote("Recording people without telling them is illegal in many places, France included. "
                + "Copy this notice and paste it in the meeting chat before you start:")
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
}

/// A labelled brushed panel, as in the rest of Settings.
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
