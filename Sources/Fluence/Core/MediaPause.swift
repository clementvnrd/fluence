import AppKit
import CoreAudio
import FluenceCore
import Foundation

/// FLU-119/121: silences the music while a dictation records and brings it back afterwards.
/// What is playing comes from CoreAudio (public, no permission); the decision is
/// `MediaPausePolicy`. Spotify and Music get their own AppleScript Pause and Play; every other
/// player (browsers, Podcasts, VLC…) is muted by a process tap for the dictation. Logs name
/// players by bundle ID only, never a title.
@MainActor
final class MediaPause {
    static let shared = MediaPause()

    private var state = MediaPausePolicy.State()

    func dictationBegan() {
        // A hold from the dictation just before carries over to this one.
        guard state.began(), Settings.shared.pauseMediaWhileDictating else { return }
        let own = Bundle.main.bundleIdentifier ?? ""
        let meeting = MeetingController.shared.isRecording
        // Never ask for System Audio Recording mid-dictation: mute only once a meeting tap asked it.
        let canMute = UserDefaults.standard.bool(forKey: MeetingPreparation.systemAudioAskedKey)
        Task {
            let processes = await Self.processes()
            let players = MediaPausePolicy.playersToPause(
                processes.map { MediaPausePolicy.AudioProcess(bundleID: $0.bundleID, isOutput: $0.isRunningOutput, isInput: $0.isRunningInput) },
                ownBundleID: own,
                meetingRecording: meeting,
                enabled: true
            )
            guard !players.isEmpty else { return }
            let split = MediaPausePolicy.split(players, canMute: canMute)
            if !canMute, players.count > split.script.count {
                Log.audio.info("media mute skipped — system audio not asked · \(players.count - split.script.count, privacy: .public) player(s)")
            }
            let tap = await Self.mute(processes.filter { split.mute.contains($0.bundleID) }.map(\.objectID))
            let scripted = await PlayerScript.run(.pause, split.script)
            Log.audio.info("media paused · \(scripted.sorted().joined(separator: ", "), privacy: .public) · muted \(tap == nil ? 0 : split.mute.count, privacy: .public): \(split.mute.sorted().joined(separator: ", "), privacy: .public)")
            let hold = MediaPausePolicy.Hold(scripted: scripted, taps: tap.map { [$0] } ?? [])
            // The dictation ended while this ran: undo at once.
            if let release = state.took(hold, meetingRecording: MeetingController.shared.isRecording) { Self.release(release) }
        }
    }

    func dictationEnded() {
        guard let release = state.ended(meetingRecording: MeetingController.shared.isRecording) else { return }
        Self.release(release)
    }

    // MARK: - System

    private static func release(_ hold: MediaPausePolicy.Hold) {
        Task {
            await unmute(hold.taps)
            let played = await PlayerScript.run(.play, hold.scripted)
            Log.audio.info("media resumed · \(played.count, privacy: .public)/\(hold.scripted.count, privacy: .public) scripted, \(hold.taps.count, privacy: .public) tap(s) removed")
        }
    }

    /// Off the main actor: the whole list takes ~60 ms to read.
    private nonisolated static func processes() async -> [CoreAudioObjects.Process] {
        CoreAudioObjects.processes()
    }

    /// `.muted`: "no audio is sent from the process to the audio hardware" (CATapDescription.h).
    /// Nothing reads the tap (no aggregate device, no IOProc), so no audio is ever captured.
    private nonisolated static func mute(_ processes: [AudioObjectID]) async -> AudioObjectID? {
        guard !processes.isEmpty else { return nil }
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.name = "Fluence media pause"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .muted
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            Log.audio.error("media mute failed: \(status)")
            return nil
        }
        return tap
    }

    private nonisolated static func unmute(_ taps: [UInt32]) async {
        for tap in taps { AudioHardwareDestroyProcessTap(tap) }
    }
}

/// Spotify's and Music's own AppleScript Pause and Play. `NSAppleScript` is not thread-safe, so
/// every script runs on one serial queue: the main actor never waits, and a Play always follows
/// its Pause. ~1 ms once AppleScript is loaded (143 ms the first time), plus the app's reply.
private enum PlayerScript {
    enum Command {
        case pause, play

        /// Acts only from the expected state, so Play never starts what the user paused themselves.
        var body: String {
            switch self {
            case .pause: "if player state is playing then\npause\nreturn true\nend if"
            case .play: "if player state is paused then\nplay\nreturn true\nend if"
            }
        }
    }

    private static let queue = DispatchQueue(label: "fluence.media.script", qos: .userInitiated)

    /// The apps the command reached in the expected state.
    static func run(_ command: Command, _ apps: Set<String>) async -> Set<String> {
        guard !apps.isEmpty else { return [] }
        let body = command.body
        return await withCheckedContinuation { continuation in
            queue.async {
                var done: Set<String> = []
                // `tell application` would launch a closed app: only those running get a script.
                for app in apps where !NSRunningApplication.runningApplications(withBundleIdentifier: app).isEmpty {
                    // The timeout bounds a hung app: the queue moves on after 2 s.
                    let source = "with timeout of 2 seconds\ntell application id \"\(app)\"\n\(body)\nend tell\nend timeout\nreturn false"
                    var error: NSDictionary?
                    if NSAppleScript(source: source)?.executeAndReturnError(&error).booleanValue == true {
                        done.insert(app)
                    } else if let error {
                        // -1743: Automation refused in System Settings.
                        Log.audio.error("media script \(app, privacy: .public) failed: \(error[NSAppleScript.errorNumber] as? Int ?? 0, privacy: .public)")
                    }
                }
                continuation.resume(returning: done)
            }
        }
    }
}
