import Foundation

// FLU-54: a meeting is recorded once, so quitting Fluence, a sentence the engine could not
// transcribe and a failed step must not lose any of it. The decisions live here, pure and
// tested; `MeetingController` and `AppDelegate` carry them out.

/// What quitting Fluence does to a meeting being recorded.
public enum QuitPlan {
    /// Who asked Fluence to quit.
    public enum Origin: Equatable, Sendable {
        /// ⌘Q, « Quitter Fluence », the Dock, a script or another app's quit event.
        case user
        /// Log out, restart or shut down: the Mac waits for Fluence, and a question would
        /// hold it up.
        case system
    }

    public enum Decision: Equatable, Sendable {
        /// Nothing records: quit at once. A final pass still running is finished at the
        /// next launch from what is saved (`RecoveryPlan`).
        case quitNow
        /// Ask « Arrêter et enregistrer la réunion ? »; on yes, stop and save, then quit.
        case ask
        /// Stop and save without asking, then quit.
        case stopAndSave
    }

    public static func decide(recording: Bool, origin: Origin) -> Decision {
        guard recording else { return .quitNow }
        return origin == .system ? .stopAndSave : .ask
    }

    /// The quit Apple event's `why?` parameter (`kAEQuitReason`) is only there when macOS
    /// quits apps for a log out, a restart or a shut down.
    public static let quitReasonKeyword = fourCharCode("why?")

    /// `quitReason`: the event's `why?` code, `nil` (or 0) when it has none or when the quit
    /// is our own `NSApp.terminate`.
    public static func origin(quitReason: UInt32?) -> Origin {
        guard let quitReason, quitReason != 0 else { return .user }
        return .system
    }

    /// How long quitting waits for the stop, the last sentences and the final pass. Past
    /// it Fluence quits anyway: the transcript is saved as soon as the last sentences are
    /// in, the audio and the recording marker stay, and the final pass runs at the next
    /// launch. Shorter for a log out or a shut down, which macOS gives up on if an app
    /// takes too long.
    public static func maximumWait(for origin: Origin) -> TimeInterval {
        origin == .system ? 15 : 30
    }

    public static let question = "Arrêter et enregistrer la réunion ?"
    public static let detail = "Une réunion est en cours d'enregistrement. Fluence l'arrête et l'enregistre avant de quitter ; cela peut prendre quelques secondes."
    public static let confirmTitle = "Arrêter et quitter"
    public static let cancelTitle = "Annuler"

    static func fourCharCode(_ code: String) -> UInt32 {
        code.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}

/// A stretch of speech the engine could not transcribe (offline on a first meeting, a model
/// error). Kept inside the encrypted meeting, with its audio, and tried again: once at the
/// end of the meeting, then at the next launches (`RecoveryPlan`). Times are seconds from
/// the meeting start, as for segments; the audio is the channel's spool at those times.
public struct UntranscribedSpan: Codable, Sendable, Hashable {
    public var source: AudioSource
    public var start: TimeInterval
    public var end: TimeInterval

    public init(source: AudioSource, start: TimeInterval, end: TimeInterval) {
        self.source = source
        self.start = start
        self.end = end
    }

    public var duration: TimeInterval { max(0, end - start) }
}

public enum TranscriptionRetry {
    /// What to try again, in time order: empty spans and repeats removed. Spans are not
    /// merged: each was one utterance, cut short enough for the engine on purpose.
    public static func plan(_ spans: [UntranscribedSpan]) -> [UntranscribedSpan] {
        var seen = Set<UntranscribedSpan>()
        return spans
            .filter { $0.start.isFinite && $0.end.isFinite && $0.duration > 0 && seen.insert($0).inserted }
            .sorted { ($0.start, $0.source.rawValue) < ($1.start, $1.source.rawValue) }
    }

    /// The meeting's list after a retry: what still failed, or `nil` when nothing is left
    /// (the field is optional so that meetings saved before FLU-54 still decode).
    public static func remaining(_ spans: [UntranscribedSpan]) -> [UntranscribedSpan]? {
        spans.isEmpty ? nil : spans
    }

    /// The panel's message when sentences are still missing at the end of a meeting.
    public static let notice = "Une partie de la réunion n'a pas pu être transcrite. Son audio est gardé sur ce Mac ; Fluence réessaiera au prochain lancement."
}

/// What finishing a meeting does with its files, once the final pass has run.
public enum MeetingCompletion {
    public struct Plan: Equatable, Sendable {
        /// Delete the audio spools.
        public var deleteAudio: Bool
        /// Remove the recording marker and the recovery count. Kept, the next launch takes
        /// the meeting up again (`RecoveryPlan`).
        public var clearMarker: Bool
        /// Tell the notes side the meeting is final, so its notes are written. Not while
        /// sentences are missing: notes wait for the whole transcript.
        public var announceFinalized: Bool
    }

    /// - Parameters:
    ///   - saved: the final save worked.
    ///   - untranscribed: spans still not transcribed.
    ///   - keepAudio: the user's per-meeting « garder l'audio ».
    public static func plan(saved: Bool, untranscribed: Int, keepAudio: Bool) -> Plan {
        guard saved else { return Plan(deleteAudio: false, clearMarker: false, announceFinalized: false) }
        guard untranscribed <= 0 else { return Plan(deleteAudio: false, clearMarker: false, announceFinalized: false) }
        return Plan(deleteAudio: !keepAudio, clearMarker: true, announceFinalized: true)
    }

    /// When recovery gives up on a meeting that only waited for missing sentences, its
    /// notes are written from what was transcribed: better than none. A meeting that never
    /// got through its final pass keeps waiting (its transcript is the live one).
    public static func announcesOnGivingUp(untranscribed: Int) -> Bool {
        untranscribed > 0
    }
}
