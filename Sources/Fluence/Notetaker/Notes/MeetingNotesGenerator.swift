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
///
/// FLU-54: each model call is tried again on a timeout or a busy model (`NotesEngine`), and
/// the notes a meeting is still owed are kept on disk beside it (`notes.job`, a count and a
/// failure label, nothing of the meeting). At launch, `resumePending()` queues again the
/// ones cut short by a quit or a crash or failed on a timeout or a busy model — at most
/// `NotesRetry.launchResumes` times — and shows the reason of the others again.
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

    /// FLU-54: at launch, takes up the notes still owed (`NotesRetry.atLaunch`). Oldest
    /// meeting first.
    func resumePending() {
        for id in store.summaries.reversed().map(\.id) {
            guard let job = readJob(id), let meeting = try? store.load(id) else { continue }
            switch NotesRetry.atLaunch(job, hasNotes: meeting.notes != nil) {
            case .forget:
                removeJob(id)
            case .resume(let counts):
                Log.app.info("meeting notes taken up again at launch (\(job.lastOutcome?.rawValue ?? "interrupted", privacy: .public))")
                enqueue(id, resumes: counts ? job.resumes + 1 : job.resumes)
            case .showFailure(let outcome):
                status[id] = .failed(NotesEngine.failure(for: outcome).message)
            }
        }
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

    /// `resumes`: launches that already took these notes up again (0 for a new request).
    private func enqueue(_ id: UUID, resumes: Int = 0) {
        guard !isBusy(id) else { return }
        // Say so at once rather than queueing work that cannot run; a later launch, with
        // Apple Intelligence on, writes them.
        if let reason = FoundationModelFormatter.unavailableReason {
            status[id] = .failed(NotesFailure.unavailable(reason).message + " " + NotesRetry.resumeNotice)
            writeJob(NotesJob(resumes: resumes, lastOutcome: .unavailable), for: id)
            return
        }
        writeJob(NotesJob(resumes: resumes), for: id)
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
            status[id] = .failed("Pas de notes : la réunion n'a pas pu être lue.")
            return
        }

        let resumes = readJob(id)?.resumes ?? 0
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
            removeJob(id)
            status[id] = nil
            Log.app.info("meeting notes written in \(Int(Date().timeIntervalSince(started)), privacy: .public)s")
            NotificationCenter.default.post(name: .meetingNotesUpdated, object: id)
        } catch let failure as NotesFailure {
            if let outcome = NotesEngine.outcome(of: failure) {
                // Kept on disk, so the reason survives a restart and a transient one is
                // taken up again at the next launch (FLU-54).
                writeJob(NotesJob(resumes: resumes, lastOutcome: outcome), for: id)
                let later = NotesRetry.willResume(after: outcome, resumes: resumes)
                status[id] = .failed(failure.message + (later ? " " + NotesRetry.resumeNotice : ""))
            } else {
                // Cancelled: the meeting is being deleted, or everything is.
                status[id] = nil
            }
            Log.app.info("meeting notes not written: \(NotesEngine.logLabel(failure), privacy: .public)")
        } catch {
            // Only the save can land here. The job stays as it is, taken up at next launch.
            let later = resumes < NotesRetry.launchResumes
            status[id] = .failed("Pas de notes : elles n'ont pas pu être enregistrées." + (later ? " " + NotesRetry.resumeNotice : ""))
            Log.app.error("meeting notes not saved: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    // MARK: - Notes owed, on disk (FLU-54)

    /// Beside the meeting, so deleting it deletes this too. Plain JSON: a count and a
    /// failure label, nothing said in the meeting.
    private func jobURL(_ id: UUID) -> URL {
        store.directory(for: id).appendingPathComponent("notes.job")
    }

    private func readJob(_ id: UUID) -> NotesJob? {
        guard let data = try? Data(contentsOf: jobURL(id)) else { return nil }
        return try? JSONDecoder().decode(NotesJob.self, from: data)
    }

    private func writeJob(_ job: NotesJob, for id: UUID) {
        // A meeting deleted meanwhile has no folder: nothing to keep.
        guard FileManager.default.fileExists(atPath: store.directory(for: id).path) else { return }
        do {
            try JSONEncoder().encode(job).write(to: jobURL(id), options: [.atomic])
        } catch {
            Log.app.error("notes job not written: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    private func removeJob(_ id: UUID) {
        try? FileManager.default.removeItem(at: jobURL(id))
    }
}
