import CoreAudio
import FluenceCore
import Foundation

/// FLU-119: pauses the music while a dictation records and plays it again afterwards.
/// What is playing comes from CoreAudio (public, no permission); the decision is
/// `MediaPausePolicy`. Logs name players by bundle ID only, never a title.
@MainActor
final class MediaPause {
    static let shared = MediaPause()

    /// Players this pause stopped; nil while Fluence holds none.
    private var paused: Set<String>?
    /// Bumped at each dictation start and end: work begun for an older one stands down.
    private var generation = 0

    func dictationBegan() {
        generation += 1
        // A pause still held from the dictation just before carries over to this one.
        guard paused == nil, Settings.shared.pauseMediaWhileDictating else { return }
        let current = generation
        let own = Bundle.main.bundleIdentifier ?? ""
        Task {
            let processes = await Self.audioProcesses()
            let players = MediaPausePolicy.playersToPause(
                processes,
                ownBundleID: own,
                meetingRecording: MeetingController.shared.isRecording,
                enabled: Settings.shared.pauseMediaWhileDictating
            )
            guard !players.isEmpty, current == generation, paused == nil, Self.send(.pause) else { return }
            paused = players
            Log.audio.info("media paused · \(players.sorted().joined(separator: ", "), privacy: .public)")
        }
    }

    func dictationEnded() {
        generation += 1
        guard let players = paused else { return }
        let current = generation
        Task {
            // A paused player can take a moment to close its audio stream: up to 1.5 s.
            for _ in 0..<15 {
                let processes = await Self.audioProcesses()
                // A new dictation began meanwhile: it keeps the pause.
                guard current == generation else { return }
                if MediaPausePolicy.shouldResume(paused: players, processes: processes, meetingRecording: MeetingController.shared.isRecording) {
                    paused = nil
                    _ = Self.send(.play)
                    Log.audio.info("media resumed · \(players.count, privacy: .public) player(s)")
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
                guard current == generation else { return }
            }
            paused = nil
            Log.audio.info("media not resumed — a paused player is still playing")
        }
    }

    // MARK: - System

    private enum Command: Int32 { case play = 0, pause = 1 }

    /// shortcut: MediaRemote is a private framework; sending still works for third-party apps
    /// on macOS 15.4+ (only its reads were closed). If Apple closes sending too, the pause
    /// silently does nothing — then weigh the media key (a toggle, needs Accessibility).
    private static let sendCommand: (@convention(c) (Int32, CFDictionary?) -> DarwinBoolean)? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
        else { return nil }
        return unsafeBitCast(symbol, to: (@convention(c) (Int32, CFDictionary?) -> DarwinBoolean).self)
    }()

    private static func send(_ command: Command) -> Bool {
        sendCommand?(command.rawValue, nil).boolValue ?? false
    }

    /// Every process CoreAudio knows, with whether it plays or records sound right now. Off the
    /// main actor: the whole list takes ~60 ms to read.
    private nonisolated static func audioProcesses() async -> [MediaPausePolicy.AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            MediaPausePolicy.AudioProcess(
                bundleID: bundleID(of: id),
                isOutput: flag(kAudioProcessPropertyIsRunningOutput, of: id),
                isInput: flag(kAudioProcessPropertyIsRunningInput, of: id)
            )
        }
    }

    private nonisolated static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private nonisolated static func flag(_ selector: AudioObjectPropertySelector, of id: AudioObjectID) -> Bool {
        var address = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr && value != 0
    }

    private nonisolated static func bundleID(of id: AudioObjectID) -> String {
        var address = address(kAudioProcessPropertyBundleID)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "" }
        return value?.takeRetainedValue() as String? ?? ""
    }
}
