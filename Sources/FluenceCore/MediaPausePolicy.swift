/// FLU-119: which players a dictation pauses, and when it may play them again.
///
/// Since macOS 15.4 a third-party app can no longer ask what is playing (MediaRemote's reads
/// answer nothing), so the only signal is CoreAudio's list of processes sending sound to an
/// output. Pause and Play reach the system's Now Playing app, which Fluence cannot name: Pause
/// is sent only while a known player is audible, and Play only once that player went quiet,
/// so nothing that was not playing is ever started.
public enum MediaPausePolicy {
    /// One process in CoreAudio's list, by bundle ID: is it playing sound, recording sound.
    public struct AudioProcess: Equatable, Sendable {
        public let bundleID: String
        public let isOutput: Bool
        public let isInput: Bool

        public init(bundleID: String, isOutput: Bool, isInput: Bool) {
            self.bundleID = bundleID
            self.isOutput = isOutput
            self.isInput = isInput
        }
    }

    /// Music, podcast and video players, and browsers (YouTube), with their helper processes.
    static let players = [
        "com.apple.music", "com.apple.podcasts", "com.apple.tv", "com.apple.quicktimeplayerx",
        "com.apple.safari", "com.apple.webkit.gpu", "com.spotify.client", "com.deezer.deezer-desktop",
        "com.tidal.desktop", "com.amazon.music", "tv.plex.plexamp", "com.colliderli.iina",
        "org.videolan.vlc", "com.google.chrome", "com.microsoft.edgemac", "com.brave.browser",
        "org.mozilla.firefox", "company.thebrowser.browser", "com.operasoftware.opera",
        "com.vivaldi.vivaldi", "net.imput.helium", "app.zen-browser.zen",
    ]

    /// Apple's always-on listening (Siri, Sound Recognition): its microphone use is not a call.
    static let listeners = ["com.apple.corespeech", "com.apple.assistantd", "com.apple.accessibility.heard"]

    /// The players to pause at key-down; empty leaves everything alone.
    public static func playersToPause(
        _ processes: [AudioProcess],
        ownBundleID: String,
        meetingRecording: Bool,
        enabled: Bool
    ) -> Set<String> {
        guard enabled, !meetingRecording else { return [] }
        let others = processes.filter { !$0.bundleID.isEmpty && !matches($0.bundleID, [ownBundleID.lowercased()]) }
        // Another app holds the microphone: a call (Zoom, FaceTime, Meet in a browser).
        if others.contains(where: { $0.isInput && !matches($0.bundleID, listeners) }) { return [] }
        return Set(others.filter { $0.isOutput && matches($0.bundleID, players) }.map(\.bundleID))
    }

    /// Play once every paused player is quiet. One still playing means the pause reached another
    /// app or the user pressed play themselves: Play would then start something.
    public static func shouldResume(paused: Set<String>, processes: [AudioProcess], meetingRecording: Bool) -> Bool {
        !paused.isEmpty && !meetingRecording && !processes.contains { $0.isOutput && paused.contains($0.bundleID) }
    }

    /// The ID itself or one of its helpers (`com.google.Chrome.helper`), never a look-alike.
    private static func matches(_ bundleID: String, _ prefixes: [String]) -> Bool {
        let id = bundleID.lowercased()
        return prefixes.contains { id == $0 || id.hasPrefix($0 + ".") }
    }
}
