import FluenceNotesCore
import Foundation
import Observation

/// State and actions of the meetings library window.
///
/// The views hold this through `@Bindable` instead of keeping their own `@State`: the
/// library is one window, its state outlives any view, and keeping it here lets the whole UI
/// be type-checked on a machine without Xcode's SwiftUI macro plugin.
@MainActor
@Observable
final class MeetingLibraryModel {
    static let shared = MeetingLibraryModel()

    enum Tab: String, CaseIterable, Identifiable {
        case recap, nextSteps, decisions, transcript, myNotes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .recap: "Recap"
            case .nextSteps: "Next steps"
            case .decisions: "Decisions"
            case .transcript: "Transcript"
            case .myNotes: "My notes"
            }
        }
    }

    let store: MeetingStore
    let generator: MeetingNotesGenerator

    // MARK: List

    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    /// IDs matching the query; nil when there is no query.
    private(set) var searchHits: Set<UUID>?

    /// Newest first, filtered by the search.
    var visible: [MeetingSummary] {
        guard let searchHits else { return store.summaries }
        return store.summaries.filter { searchHits.contains($0.id) }
    }

    // MARK: Selection

    var selectedID: UUID? {
        didSet { if selectedID != oldValue { loadSelected() } }
    }
    /// The decrypted selected meeting.
    private(set) var meeting: Meeting?
    private(set) var template: NotesTemplate = .general
    var tab: Tab = .recap

    // MARK: Editing

    var isEditingTitle = false
    var titleDraft = ""
    var notesDraft = ""
    /// The speaker being renamed (drives the rename sheet).
    var renaming: Speaker?
    var renameDraft = ""

    var isConfirmingDelete = false
    var isConfirmingRegenerate = false

    /// The last thing that went wrong in this window (load, save), shown in the banner.
    private(set) var problem: String?
    /// Short-lived confirmation on a key ("Copied").
    private(set) var flash: String?

    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var flashTask: Task<Void, Never>?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(store: MeetingStore = .shared, generator: MeetingNotesGenerator = .shared) {
        self.store = store
        self.generator = generator
        observer = NotificationCenter.default.addObserver(
            forName: .meetingNotesUpdated,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let id = notification.object as? UUID else { return }
            Task { @MainActor in self?.notesUpdated(id) }
        }
    }

    /// What the banner says: the store's own error first (Keychain locked or denied), then
    /// this window's.
    var bannerMessage: String? {
        store.lastError ?? problem
    }

    func dismissProblem() {
        problem = nil
    }

    // MARK: - Search

    /// Search decrypts each meeting, so it waits for a pause in typing.
    private func scheduleSearch() {
        searchTask?.cancel()
        let query = query
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            searchHits = nil
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: DS.Library.searchDebounce)
            guard !Task.isCancelled, let self else { return }
            self.searchHits = Set(self.store.search(query).map(\.id))
        }
    }

    // MARK: - Selection

    func select(_ id: UUID) {
        selectedID = id
    }

    private func loadSelected() {
        isEditingTitle = false
        renaming = nil
        guard let selectedID else {
            meeting = nil
            return
        }
        do {
            let loaded = try store.load(selectedID)
            meeting = loaded
            notesDraft = loaded.userNotes
            template = NotesTemplateChoice.template(for: selectedID)
            problem = nil
        } catch {
            meeting = nil
            problem = "This meeting could not be decrypted."
        }
    }

    private func notesUpdated(_ id: UUID) {
        guard id == selectedID, let fresh = try? store.load(id) else { return }
        // Keep unsaved "My notes" typing; take everything else from disk.
        let draft = notesDraft
        meeting = fresh
        notesDraft = draft
    }

    // MARK: - Editing

    func beginEditingTitle() {
        titleDraft = meeting?.title ?? ""
        isEditingTitle = true
    }

    func commitTitle() {
        isEditingTitle = false
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var meeting, !title.isEmpty, title != meeting.title else { return }
        meeting.title = title
        save(meeting)
    }

    func beginRenaming(_ speaker: Speaker) {
        renameDraft = speaker.name ?? ""
        renaming = speaker
    }

    func commitRename() {
        guard let speaker = renaming, var meeting else { return }
        renaming = nil
        meeting.renameSpeaker(speaker.id, to: renameDraft)
        save(meeting)
    }

    var hasUnsavedNotes: Bool {
        guard let meeting else { return false }
        return notesDraft != meeting.userNotes
    }

    func saveUserNotes() {
        guard var meeting, hasUnsavedNotes else { return }
        meeting.userNotes = notesDraft
        save(meeting)
    }

    func setTemplate(_ template: NotesTemplate) {
        guard let selectedID else { return }
        NotesTemplateChoice.set(template, for: selectedID)
        self.template = template
    }

    private func save(_ updated: Meeting) {
        do {
            try store.save(updated)
            meeting = updated
            problem = nil
        } catch {
            problem = "The change could not be saved."
        }
    }

    // MARK: - Notes

    var status: MeetingNotesGenerator.Status? {
        selectedID.flatMap { generator.status[$0] }
    }

    /// Asks first when notes exist: regenerating replaces them.
    func requestRegenerate() {
        guard meeting != nil else { return }
        if meeting?.notes != nil {
            isConfirmingRegenerate = true
        } else {
            regenerate()
        }
    }

    func regenerate() {
        guard let selectedID else { return }
        // Save typed notes first: they are part of what the model reads.
        saveUserNotes()
        generator.regenerate(selectedID)
    }

    // MARK: - Delete

    func deleteSelected() {
        guard let id = selectedID else { return }
        generator.cancel(id)
        store.delete(id)
        NotesTemplateChoice.forget(id)
        searchHits?.remove(id)
        selectedID = visible.first?.id
    }

    /// After meetings were deleted elsewhere (retention, "Delete all"): drops a selection
    /// or search hits that no longer exist.
    func reconcile() {
        let ids = Set(store.summaries.map(\.id))
        if let hits = searchHits { searchHits = hits.intersection(ids) }
        if let selectedID, !ids.contains(selectedID) {
            self.selectedID = visible.first?.id
        }
    }

    // MARK: - Feedback

    func showFlash(_ text: String) {
        flash = text
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: DS.Library.flashDuration)
            guard !Task.isCancelled else { return }
            self?.flash = nil
        }
    }

    func report(_ message: String) {
        problem = message
    }
}
