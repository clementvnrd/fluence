import FluenceNotesCore
import Foundation
import Observation

extension Notification.Name {
    /// Posted on the main actor after notes for a meeting were saved. `object` is the
    /// meeting's `UUID`. The library reloads the meeting it shows.
    static let meetingNotesUpdated = Notification.Name("FluenceMeetingNotesUpdated")
}

/// Writes meeting notes: automatically when a meeting is finalized, and on demand
/// ("Regenerate notes").
///
/// One generation at a time — the on-device model serves one request at a time anyway —
/// from a FIFO queue. The result is applied to a freshly loaded copy of the meeting, so a
/// rename or title edit made while the model was working is kept. If the model is
/// unavailable or fails, nothing is saved and the reason is kept in `status` for the UI.
@MainActor
@Observable
final class MeetingNotesGenerator {
    static let shared = MeetingNotesGenerator()

    enum Status: Equatable {
        case queued
        case working(NotesProgress)
        case failed(String)
    }

    /// Per meeting; absent when idle with nothing to report.
    private(set) var status: [UUID: Status] = [:]

    @ObservationIgnored private let store: MeetingStore
    @ObservationIgnored private let engine = NotesEngine()
    @ObservationIgnored private var queue: [UUID] = []
    @ObservationIgnored private var current: (id: UUID, task: Task<Void, Never>)?
    @ObservationIgnored private var observer: NSObjectProtocol?

    init(store: MeetingStore = .shared) {
        self.store = store
    }

    /// Starts listening for `.meetingFinalized`. Idempotent.
    func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: .meetingFinalized,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let id = notification.object as? UUID else { return }
            // Hop explicitly: `MainActor.assumeIsolated` asserts rather than checks, and
            // has taken this app down before (AGENTS.md).
            Task { @MainActor in self?.meetingFinalized(id) }
        }
    }

    /// The capture side finished a meeting. Writes notes unless it already has some.
    func meetingFinalized(_ id: UUID) {
        guard let meeting = try? store.load(id) else { return }
        guard meeting.notes == nil else { return }
        enqueue(id)
    }

    /// Writes notes again, replacing the current ones once (and only if) the new ones are
    /// ready. The UI confirms before calling this when notes exist.
    func regenerate(_ id: UUID) {
        enqueue(id)
    }

    func isBusy(_ id: UUID) -> Bool {
        switch status[id] {
        case .queued, .working: true
        default: false
        }
    }

    /// Stops work on a meeting being deleted.
    func cancel(_ id: UUID) {
        queue.removeAll { $0 == id }
        if current?.id == id { current?.task.cancel() }
        status[id] = nil
    }

    func cancelAll() {
        queue.removeAll()
        current?.task.cancel()
        status.removeAll()
    }

    // MARK: - Queue

    private func enqueue(_ id: UUID) {
        guard !isBusy(id) else { return }
        // Say so at once rather than queueing work that cannot run.
        if let reason = FoundationModelFormatter.unavailableReason {
            status[id] = .failed(NotesFailure.unavailable(reason).message)
            return
        }
        status[id] = .queued
        queue.append(id)
        runNext()
    }

    private func runNext() {
        guard current == nil, !queue.isEmpty else { return }
        let id = queue.removeFirst()
        let task = Task { [weak self] in
            await self?.generate(id)
            self?.current = nil
            self?.runNext()
        }
        current = (id, task)
    }

    private func generate(_ id: UUID) async {
        let meeting: Meeting
        do {
            meeting = try store.load(id)
        } catch {
            status[id] = .failed("No notes: the meeting could not be read.")
            return
        }

        status[id] = .working(.preparing)
        let request = meeting.notesRequest(template: NotesTemplateChoice.template(for: id))
        let started = Date()
        do {
            let draft = try await engine.generate(request) { [weak self] progress in
                guard let self, self.isBusy(id) else { return }
                self.status[id] = .working(progress)
            }
            guard !Task.isCancelled else { status[id] = nil; return }
            // Reload: the user may have renamed a speaker or edited the title meanwhile,
            // and the meeting may have been deleted.
            guard var fresh = try? store.load(id) else { status[id] = nil; return }
            fresh.notes = MeetingNotes(draft)
            try store.save(fresh)
            status[id] = nil
            Log.app.info("meeting notes written in \(Int(Date().timeIntervalSince(started)), privacy: .public)s")
            NotificationCenter.default.post(name: .meetingNotesUpdated, object: id)
        } catch let failure as NotesFailure {
            status[id] = failure == .cancelled ? nil : .failed(failure.message)
            Log.app.info("meeting notes not written: \(NotesEngine.logLabel(failure), privacy: .public)")
        } catch {
            // Only the save can land here.
            status[id] = .failed("No notes: they could not be saved.")
            Log.app.error("meeting notes not saved: \(String(describing: type(of: error)), privacy: .public)")
        }
    }
}
