import Foundation

/// FLU-32: what to do with a meeting found interrupted at launch (its recording marker
/// still there). Every attempt is counted on disk before it starts, so a crash inside the
/// final pass counts too and cannot repeat at every launch.
public enum RecoveryPlan {
    public static let maxAttempts = 2

    public enum Decision: Equatable, Sendable {
        /// Run the final pass again; `number` is this attempt's count, to write first.
        case attempt(number: Int)
        /// Leave the files as they are. `announce` is true once, the first time.
        case giveUp(announce: Bool)
    }

    public static func decide(previousAttempts: Int) -> Decision {
        let done = max(0, previousAttempts)
        if done < maxAttempts { return .attempt(number: done + 1) }
        return .giveUp(announce: done == maxAttempts)
    }

    /// The count written after announcing, so the next launch stays quiet.
    public static let announcedCount = maxAttempts + 1
}

/// FLU-32: when to rebuild a system-audio tap that went silent while the meeting app plays.
/// The first rebuild comes as soon as five seconds of silence are seen; then the waits
/// double, 5, 10, 20, 40 s, and stay at 60 s. There is no limit on their number: a call
/// can last hours, and a tap that comes back late is worth more than one given up on.
public enum TapWatchdog {
    /// Silence on the tap, while the app plays, before anything is done.
    public static let silenceThreshold: TimeInterval = 5

    /// Wait after the `rebuilds`-th rebuild before the next one.
    public static func delay(afterRebuilds rebuilds: Int) -> TimeInterval {
        guard rebuilds > 0 else { return 0 }
        return min(60, 5 * pow(2, Double(min(rebuilds, 8) - 1)))
    }

    /// - Parameters:
    ///   - silentFor: seconds since the tap last carried sound.
    ///   - sinceLastRebuild: seconds since the last rebuild; `nil` if none in this silence.
    ///   - rebuilds: rebuilds already made during this silence.
    public static func isRebuildDue(silentFor: TimeInterval, sinceLastRebuild: TimeInterval?, rebuilds: Int) -> Bool {
        guard silentFor >= silenceThreshold else { return false }
        guard let sinceLastRebuild else { return true }
        return sinceLastRebuild >= delay(afterRebuilds: rebuilds)
    }

    /// The message while the call's sound is missing, after a rebuild did not bring it back.
    public static func notice(nextTryIn seconds: TimeInterval) -> String {
        "Le son de l'appel est coupé. Fluence réessaie dans \(Int(seconds.rounded()))\u{00A0}s ; votre micro continue d'être enregistré."
    }
}

/// FLU-32: a meeting's audio blocks wait in a bounded queue for transcription. When the
/// queue is full the oldest blocks are dropped; that is said, never hidden.
public enum DroppedAudio {
    public static func notice(blocks: Int) -> String? {
        guard blocks > 0 else { return nil }
        return "La transcription prend du retard : une partie de l'audio n'a pas pu être gardée."
    }
}
