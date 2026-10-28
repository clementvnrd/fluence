import Testing

@testable import FluenceCore

/// FLU-119: the music pauses while a dictation records, and plays again only if Fluence paused it.
struct MediaPausePolicyTests {
    typealias P = MediaPausePolicy.AudioProcess
    let own = "io.github.clementvnrd.fluence"

    func pause(_ processes: [P], meeting: Bool = false, enabled: Bool = true) -> Set<String> {
        MediaPausePolicy.playersToPause(processes, ownBundleID: own, meetingRecording: meeting, enabled: enabled)
    }

    @Test func aPlayingPlayerIsPaused() {
        #expect(pause([P("com.spotify.client", output: true)]) == ["com.spotify.client"])
        #expect(pause([P("com.apple.Music", output: true)]) == ["com.apple.Music"])
        // Browsers play through helper processes: YouTube in Chrome, Safari's WebKit GPU process.
        #expect(pause([P("com.google.Chrome.helper", output: true)]) == ["com.google.Chrome.helper"])
        #expect(pause([P("com.apple.WebKit.GPU", output: true)]) == ["com.apple.WebKit.GPU"])
    }

    @Test func nothingPlayingMeansNothingSent() {
        #expect(pause([]).isEmpty)
        #expect(pause([P("com.spotify.client")]).isEmpty)
    }

    @Test func fluencesOwnSoundAndOtherAppsAreNotMedia() {
        #expect(pause([P(own, output: true, input: true)]).isEmpty)
        #expect(pause([P("com.apple.PowerChime", output: true), P("systemsoundserverd", output: true)]).isEmpty)
        #expect(pause([P("us.zoom.xos", output: true)]).isEmpty)
        // A look-alike prefix is not the player.
        #expect(pause([P("com.apple.Musicrecognition", output: true)]).isEmpty)
    }

    @Test func aCallOrAMeetingLeavesEverythingAlone() {
        let music = P("com.spotify.client", output: true)
        // Someone else holds the microphone: Zoom, FaceTime, Meet in a browser.
        #expect(pause([music, P("us.zoom.xos", output: true, input: true)]).isEmpty)
        #expect(pause([music, P("com.google.Chrome.helper", input: true)]).isEmpty)
        #expect(pause([music], meeting: true).isEmpty)
        #expect(pause([music], enabled: false).isEmpty)
        // Siri's and Sound Recognition's always-on listening is not a call.
        #expect(pause([music, P("com.apple.CoreSpeech", input: true)]) == ["com.spotify.client"])
    }

    @Test func playResumesOnlyOncePausedPlayersWentQuiet() {
        let paused: Set<String> = ["com.spotify.client"]
        #expect(MediaPausePolicy.shouldResume(paused: paused, processes: [P("com.spotify.client")], meetingRecording: false))
        #expect(MediaPausePolicy.shouldResume(paused: paused, processes: [], meetingRecording: false))
        // Still playing: the pause reached another app, or the user pressed play — Play would start something.
        #expect(!MediaPausePolicy.shouldResume(paused: paused, processes: [P("com.spotify.client", output: true)], meetingRecording: false))
        #expect(!MediaPausePolicy.shouldResume(paused: [], processes: [], meetingRecording: false))
        #expect(!MediaPausePolicy.shouldResume(paused: paused, processes: [], meetingRecording: true))
    }
}

private extension MediaPausePolicy.AudioProcess {
    init(_ bundleID: String, output: Bool = false, input: Bool = false) {
        self.init(bundleID: bundleID, isOutput: output, isInput: input)
    }
}
