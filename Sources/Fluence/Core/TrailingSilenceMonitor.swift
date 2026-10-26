import AVFoundation
import Darwin
import FluenceCore
import Synchronization

/// The host clock the capture stamps its buffers with, in seconds.
enum HostClock {
    static var now: TimeInterval { AVAudioTime.seconds(forHostTime: mach_absolute_time()) }
}

/// Follows where the last sound ended in a dictation's capture, so the post-roll can close
/// the microphone early when the speaker had already finished (FLU-31, `PostRoll`).
///
/// Written from the tap callback (AVAudioEngine's tap thread, which already allocates a copy
/// of every buffer — not the real-time I/O thread), read from the main actor while the
/// post-roll waits. The lock is held for one buffer's arithmetic or one copy.
final class TrailingSilenceMonitor: Sendable {
    private let state = Mutex(TrailingSilence())

    /// A captured chunk without a host time is ignored: the post-roll then falls back to
    /// its full length.
    func observe(_ chunk: AudioChunk) {
        guard let time = chunk.captureTime,
              let samples = chunk.buffer.floatChannelData?[0]
        else { return }
        let buffer = UnsafeBufferPointer(start: samples, count: Int(chunk.buffer.frameLength))
        let rate = chunk.buffer.format.sampleRate
        state.withLock { $0.observe(buffer, sampleRate: rate, startTime: time) }
    }

    var snapshot: TrailingSilence.Snapshot {
        state.withLock { $0.snapshot }
    }
}
