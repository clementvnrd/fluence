/// FLU-119: which players a dictation pauses, and how it gives them back.
///
/// Since macOS 15.4 a third-party app can no longer ask what is playing (MediaRemote's reads
/// answer nothing), so the only signal is CoreAudio's list of processes sending sound to an
/// output.
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

    /// Players with their own AppleScript Pause and Play, by the bundle ID `tell application id` needs.
    static let scriptable = ["com.spotify.client": "com.spotify.client", "com.apple.music": "com.apple.Music"]

    /// FLU-121: one system-wide Pause reaches only macOS's Now Playing app (YouTube in front,
    /// Spotify behind kept playing). Spotify and Music get their own script; every other player
    /// is muted by a process tap, and only when System Audio Recording was already asked.
    public static func split(_ players: Set<String>, canMute: Bool) -> (script: Set<String>, mute: Set<String>) {
        var script: Set<String> = []
        var mute: Set<String> = []
        for player in players {
            if let app = scriptable.first(where: { matches(player, [$0.key]) })?.value {
                script.insert(app)
            } else if canMute {
                mute.insert(player)
            }
        }
        return (script, mute)
    }

    /// What Fluence holds while dictating: the apps it paused by script, the taps muting the others.
    public struct Hold: Equatable, Sendable {
        public var scripted: Set<String>
        public var taps: [UInt32]

        public init(scripted: Set<String> = [], taps: [UInt32] = []) {
            self.scripted = scripted
            self.taps = taps
        }

        var isEmpty: Bool { scripted.isEmpty && taps.isEmpty }
    }

    /// The hold across dictations. The lookup runs after key-down and can finish after the key
    /// is up, or after the next dictation began: it then belongs to whichever is current.
    public struct State: Sendable {
        private var held = Hold()
        private var dictating = false

        public init() {}

        /// Key-down: true when players must be looked up, false while a hold carries over.
        public mutating func began() -> Bool {
            dictating = true
            return held.isEmpty
        }

        /// The lookup paused or muted `more`; returns what to undo now if no dictation runs.
        public mutating func took(_ more: Hold, meetingRecording: Bool) -> Hold? {
            held.scripted.formUnion(more.scripted)
            held.taps += more.taps
            return dictating ? nil : ended(meetingRecording: meetingRecording)
        }

        /// Key-up, cancel or failure: what to undo. Taps always go, so nothing stays muted; no
        /// Play while a meeting records.
        public mutating func ended(meetingRecording: Bool) -> Hold? {
            dictating = false
            guard !held.isEmpty else { return nil }
            defer { held = Hold() }
            return Hold(scripted: meetingRecording ? [] : held.scripted, taps: held.taps)
        }
    }

    /// The ID itself or one of its helpers (`com.google.Chrome.helper`), never a look-alike.
    private static func matches(_ bundleID: String, _ prefixes: [String]) -> Bool {
        let id = bundleID.lowercased()
        return prefixes.contains { id == $0 || id.hasPrefix($0 + ".") }
    }
}
