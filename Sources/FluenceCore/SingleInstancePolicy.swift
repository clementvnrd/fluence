import Foundation

/// One Fluence at a time (FLU-27): which running copy a launch hands over to.
///
/// Two copies each hold the dictation shortcut, so every dictation was typed twice, and both
/// wrote the same files. A second copy (a zip opened from Downloads, a build launched beside
/// the installed app) brings the running one forward and quits before it touches anything.
public enum SingleInstancePolicy {
    public struct Copy: Equatable, Sendable {
        public let pid: Int32
        public let launched: Date?

        public init(pid: Int32, launched: Date?) {
            self.pid = pid
            self.launched = launched
        }
    }

    /// - Parameters:
    ///   - copies: the running apps with this bundle ID, this one included.
    ///   - own: this process.
    ///   - isScratch: a development run on a scratch folder (`FLUENCE_SUPPORT_DIRECTORY`),
    ///     which shares no file with the running copy and may run beside it.
    ///   - isAlive: whether a process still exists. `make run` quits the old copy and opens
    ///     the new one at once, so a copy on its way out can still be listed.
    /// - Returns: the copy to bring forward before quitting, or nil to start. Only a copy
    ///   launched before this one counts, so two copies opened together never both quit.
    public static func copyToYieldTo(
        copies: [Copy],
        own: Int32,
        isScratch: Bool,
        isAlive: (Int32) -> Bool
    ) -> Copy? {
        guard !isScratch, let me = copies.first(where: { $0.pid == own }) else { return nil }
        return copies
            .filter { $0.pid != own && isAlive($0.pid) && isOlder($0, than: me) }
            .min { isOlder($0, than: $1) }
    }

    /// Earlier launch first; the lower process ID breaks a tie or a missing date.
    static func isOlder(_ a: Copy, than b: Copy) -> Bool {
        switch (a.launched, b.launched) {
        case let (x?, y?) where x != y: x < y
        default: a.pid < b.pid
        }
    }
}
