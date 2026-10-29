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

    // FLU-121: one global Pause reached only macOS's Now Playing app (YouTube in front, Spotify missed).

    @Test func spotifyAndMusicGoByScriptEveryOtherPlayerIsMuted() {
        let players: Set<String> = ["com.spotify.client", "com.apple.Music", "net.imput.helium.helper", "com.apple.WebKit.GPU", "com.apple.podcasts"]
        let split = MediaPausePolicy.split(players, canMute: true)
        #expect(split.script == ["com.spotify.client", "com.apple.Music"])
        #expect(split.mute == ["net.imput.helium.helper", "com.apple.WebKit.GPU", "com.apple.podcasts"])
        // CoreAudio's spelling or a helper process still scripts the app itself, by its real bundle ID.
        #expect(MediaPausePolicy.split(["com.apple.music", "com.spotify.client.helper"], canMute: true).script == ["com.apple.Music", "com.spotify.client"])
        #expect(MediaPausePolicy.split([], canMute: true).script.isEmpty)
    }

    @Test func withoutSystemAudioRecordingNothingIsMuted() {
        let split = MediaPausePolicy.split(["com.spotify.client", "net.imput.helium.helper"], canMute: false)
        #expect(split.script == ["com.spotify.client"])
        #expect(split.mute.isEmpty)
    }

    typealias Hold = MediaPausePolicy.Hold

    @Test func theEndUnmutesAndPlaysWhatThisDictationPausedOnce() {
        var state = MediaPausePolicy.State()
        let r1 = state.began()
        #expect(r1)
        let r2 = state.took(Hold(scripted: ["com.spotify.client"], taps: [7]), meetingRecording: false)
        #expect(r2 == nil)
        let r3 = state.ended(meetingRecording: false)
        #expect(r3 == Hold(scripted: ["com.spotify.client"], taps: [7]))
        let r4 = state.ended(meetingRecording: false)
        #expect(r4 == nil)
        // Nothing taken, nothing to undo.
        let r5 = state.began()
        #expect(r5)
        let r6 = state.ended(meetingRecording: false)
        #expect(r6 == nil)
    }

    @Test func aMeetingStartedMeanwhileStillUnmutesButPlaysNothing() {
        var state = MediaPausePolicy.State()
        _ = state.began()
        _ = state.took(Hold(scripted: ["com.spotify.client"], taps: [7]), meetingRecording: false)
        let r7 = state.ended(meetingRecording: true)
        #expect(r7 == Hold(scripted: [], taps: [7]))
    }

    @Test func aDictationEndedBeforeTheLookupFinishedIsUndoneAtOnce() {
        var state = MediaPausePolicy.State()
        _ = state.began()
        let r8 = state.ended(meetingRecording: false)
        #expect(r8 == nil)
        let r9 = state.took(Hold(scripted: ["com.apple.Music"], taps: [3]), meetingRecording: false)
        #expect(r9 == Hold(scripted: ["com.apple.Music"], taps: [3]))
        let r10 = state.ended(meetingRecording: false)
        #expect(r10 == nil)
    }

    @Test func aNewDictationKeepsTheHoldAndTheEndUndoesAllOfIt() {
        var state = MediaPausePolicy.State()
        _ = state.began()
        _ = state.took(Hold(scripted: ["com.spotify.client"], taps: [7]), meetingRecording: false)
        // Began again before the end: no second lookup, the hold carries over.
        let r11 = state.began()
        #expect(!r11)
        let r12 = state.ended(meetingRecording: false)
        #expect(r12 == Hold(scripted: ["com.spotify.client"], taps: [7]))

        // Back to back while the first lookup is still running: both lookups belong to the second dictation.
        _ = state.began()
        _ = state.ended(meetingRecording: false)
        let r13 = state.began()
        #expect(r13)
        let r14 = state.took(Hold(scripted: ["com.spotify.client"], taps: [7]), meetingRecording: false)
        #expect(r14 == nil)
        let r15 = state.took(Hold(taps: [8]), meetingRecording: false)
        #expect(r15 == nil)
        let r16 = state.ended(meetingRecording: false)
        #expect(r16 == Hold(scripted: ["com.spotify.client"], taps: [7, 8]))
    }
}

private extension MediaPausePolicy.AudioProcess {
    init(_ bundleID: String, output: Bool = false, input: Bool = false) {
        self.init(bundleID: bundleID, isOutput: output, isInput: input)
    }
}
