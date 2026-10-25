import Foundation

// FLU-54: notes that time out or find the on-device model busy are tried again, first
// within the generation (each model call, with a backoff), then at the next launch. What is
// pending or failed is kept on disk beside the meeting, so a restart neither forgets it nor
// hides the reason.

/// How a notes generation last ended without notes, as kept on disk. Labels only, never
/// any of the model's text.
public enum NotesOutcome: String, Codable, Sendable, CaseIterable {
    case timedOut
    /// The model was rate limited or serving another request.
    case busy
    /// Apple Intelligence off, not supported or still downloading.
    case unavailable
    case tooShort
    case declined
    case unsupportedLanguage
    case empty
    case failed

    /// Worth trying again on its own later: the same transcript may well work next time.
    public var isTransient: Bool {
        switch self {
        case .timedOut, .busy, .unavailable: true
        case .tooShort, .declined, .unsupportedLanguage, .empty, .failed: false
        }
    }
}

/// One meeting's notes still owed: written when a generation is queued, removed once the
/// notes are saved. A file left at quit or crash means the work was interrupted.
public struct NotesJob: Codable, Sendable, Equatable {
    /// Launches that took this meeting's notes up again.
    public var resumes: Int
    /// `nil` while queued or running, or when the run was cut short (quit, crash).
    public var lastOutcome: NotesOutcome?

    public init(resumes: Int = 0, lastOutcome: NotesOutcome? = nil) {
        self.resumes = resumes
        self.lastOutcome = lastOutcome
    }
}

public enum NotesRetry {
    // MARK: Within one generation

    /// Tries of one model call before its failure fails the generation.
    public static let callAttempts = 3

    /// Each try of a call gets a little longer than the last: a slow Mac (or one busy with
    /// a call) may just need more than the first limit. 90 s, 135 s, 180 s by default.
    public static func callTimeout(attempt: Int, base: TimeInterval) -> TimeInterval {
        base * (1 + 0.5 * Double(max(1, attempt) - 1))
    }

    /// The wait before try `attempt` (2…`callAttempts`) of a call whose last try ended
    /// with `outcome`; `nil` when it is not tried again. Only a timeout and a busy model
    /// are: anything else would fail the same way. A busy model gets a backoff (10 s, then
    /// 30 s); a timeout is retried after a short breath, the longer limit doing the work.
    public static func delay(beforeAttempt attempt: Int, after outcome: NotesOutcome) -> TimeInterval? {
        guard attempt >= 2, attempt <= callAttempts else { return nil }
        switch outcome {
        case .busy: return 10 * pow(3, Double(attempt - 2))
        case .timedOut: return 2
        default: return nil
        }
    }

    // MARK: Across launches

    /// Launches that may take a meeting's notes up again on their own.
    public static let launchResumes = 2

    public enum LaunchDecision: Equatable, Sendable {
        /// Queue the notes again. `counts` is false while the model is unavailable: waiting
        /// for Apple Intelligence costs nothing and must not use up the tries.
        case resume(counts: Bool)
        /// Leave it, but show why there are no notes (the reason survives the restart).
        case showFailure(NotesOutcome)
        /// Nothing to do: the job file can go.
        case forget
    }

    /// - Parameters:
    ///   - job: the job found beside the meeting.
    ///   - hasNotes: the meeting has notes already (written by another path).
    public static func atLaunch(_ job: NotesJob, hasNotes: Bool) -> LaunchDecision {
        if hasNotes { return .forget }
        guard let outcome = job.lastOutcome else {
            // Cut short by a quit or a crash.
            return job.resumes < launchResumes ? .resume(counts: true) : .showFailure(.failed)
        }
        if outcome == .unavailable { return .resume(counts: false) }
        guard outcome.isTransient else { return .showFailure(outcome) }
        return job.resumes < launchResumes ? .resume(counts: true) : .showFailure(outcome)
    }

    /// Whether a job that just ended with `outcome` will be taken up at a later launch, so
    /// the message can say so.
    public static func willResume(after outcome: NotesOutcome, resumes: Int) -> Bool {
        if outcome == .unavailable { return true }
        return outcome.isTransient && resumes < launchResumes
    }

    public static let resumeNotice = "Fluence réessaiera au prochain lancement."
}
