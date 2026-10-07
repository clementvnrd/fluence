import FluenceNotesCore
import Foundation
import Observation

/// State and actions of the meetings library: the list and a meeting's page, in the main
/// window since FLU-12.
///
/// The views hold this through `@Bindable` instead of keeping their own `@State`: the
/// library is one window, its state outlives any view, and keeping it here lets the whole UI
/// be type-checked on a machine without Xcode's SwiftUI macro plugin.
@MainActor
@Observable
final class MeetingLibraryModel {
    static let shared = MeetingLibraryModel()

    /// The meeting page's tabs (FLU-12, mock-ups 04 and 05).
    enum Tab: String, CaseIterable, Identifiable {
        case notes, transcript, myNotes
        var id: String { rawValue }
        var title: String {
            switch self {
            case .notes: "Notes"
            case .transcript: "Transcription"
            case .myNotes: "Mes notes"
            }
        }
        var symbol: String {
            switch self {
            case .notes: "list.bullet.rectangle"
            case .transcript: "text.quote"
            case .myNotes: "square.and.pencil"
            }
        }
    }

    /// What a list row shows beyond the index's basics. Read from the summary, or — for an
    /// index entry written before FLU-12 — from the meeting itself, once, kept in memory.
    struct RowInfo: Equatable {
        var appBundleID: String?
        var recapLine: String?
        var keepAudio: Bool
        var speakers: [Speaker]
        var isImported = false

        var appName: String? { appBundleID.flatMap { MeetingApps.identify($0)?.name } }
    }

    let store: MeetingStore
    /// "Importer" (FLU-16): past meetings from transcript files or pasted text.
    let importer = MeetingImportModel()
    let generator: MeetingNotesGenerator

    // MARK: List

    var query = "" {
        didSet { if query != oldValue { scheduleSearch() } }
    }
    /// IDs matching the query; nil when there is no query.
    private(set) var searchHits: Set<UUID>?

    /// Bundle ID of the app the list is filtered to ("Toutes les apps" when nil).
    var appFilter: String?

    /// Newest first, filtered by the search and the app.
    var visible: [MeetingSummary] {
        var list = store.summaries
        if let searchHits { list = list.filter { searchHits.contains($0.id) } }
        if let appFilter { list = list.filter { rowInfo($0).appBundleID == appFilter } }
        return list
    }

    /// The apps meetings were recorded in, for the filter; empty when there is only one.
    var apps: [(bundleID: String, name: String)] {
        var seen: [String: String] = [:]
        for summary in store.summaries {
            let info = rowInfo(summary)
            if let id = info.appBundleID, let name = info.appName { seen[id] = name }
        }
        guard seen.count > 1 else { return [] }
        return seen.map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
    }

    @ObservationIgnored private var rowInfoCache: [UUID: RowInfo] = [:]

    func rowInfo(_ summary: MeetingSummary) -> RowInfo {
        if let speakers = summary.speakers {
            return RowInfo(
                appBundleID: summary.appBundleID,
                recapLine: summary.recapLine,
                keepAudio: summary.keepAudio ?? false,
                speakers: speakers,
                isImported: summary.isImported ?? false
            )
        }
        if let cached = rowInfoCache[summary.id] { return cached }
        let info: RowInfo
        if let meeting = try? store.load(summary.id) {
            let fresh = MeetingSummary(meeting)
            info = RowInfo(appBundleID: fresh.appBundleID, recapLine: fresh.recapLine, keepAudio: meeting.keepAudio, speakers: meeting.speakers, isImported: meeting.trigger == .imported)
        } else {
            info = RowInfo(appBundleID: nil, recapLine: nil, keepAudio: false, speakers: [])
        }
        rowInfoCache[summary.id] = info
        return info
    }

    // MARK: Page

    /// The selected meeting is shown on its own page instead of the list.
    private(set) var isPageOpen = false

    func openPage(_ id: UUID) {
        select(id)
        tab = .notes
        isPageOpen = meeting != nil
    }

    func closePage() {
        isPageOpen = false
        isEditingTitle = false
        renaming = nil
        transcriptQuery = ""
    }

    /// The transcript tab's own search.
    var transcriptQuery = ""

    // MARK: Selection

    var selectedID: UUID? {
        didSet { if selectedID != oldValue { loadSelected() } }
    }
    /// The decrypted selected meeting.
    private(set) var meeting: Meeting?
    private(set) var template: NotesTemplate = .general
    var tab: Tab = .notes

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
            problem = "Cette réunion n'a pas pu être déchiffrée."
        }
    }

    private func notesUpdated(_ id: UUID) {
        rowInfoCache[id] = nil
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

    /// Calendar invitees not yet given to a speaker: the rename popover's suggestions.
    var renameSuggestions: [String] {
        guard let meeting else { return [] }
        let used = Set(meeting.speakers.compactMap(\.name).map { $0.lowercased() })
        return meeting.attendees.filter { !used.contains($0.lowercased()) }
    }

    /// How many times a speaker spoke in the open meeting.
    func interventions(of speakerID: String) -> Int {
        meeting?.segments.count { $0.speakerID == speakerID } ?? 0
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
        rowInfoCache[updated.id] = nil
        do {
            try store.save(updated)
            meeting = updated
            problem = nil
        } catch {
            problem = "La modification n'a pas pu être enregistrée."
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
        rowInfoCache[id] = nil
        selectedID = nil
        closePage()
    }

    /// After meetings were deleted elsewhere (retention, "Delete all"): drops a selection
    /// or search hits that no longer exist.
    func reconcile() {
        let ids = Set(store.summaries.map(\.id))
        if let hits = searchHits { searchHits = hits.intersection(ids) }
        if let selectedID, !ids.contains(selectedID) {
            self.selectedID = nil
            closePage()
        }
        rowInfoCache = rowInfoCache.filter { ids.contains($0.key) }
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
