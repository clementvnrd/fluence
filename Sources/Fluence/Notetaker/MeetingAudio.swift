import AVFoundation
import CoreAudio
import Foundation

/// One block of meeting audio in transit from a capture thread to its channel pipeline:
/// 16 kHz mono Float32, stamped with the host clock time of its first sample.
///
/// The dictation path's `AudioChunk` is deliberately left alone; meetings need the host
/// time and the source, dictation needs neither.
struct CapturedAudio: Sendable {
    var samples: [Float]
    /// `mach_absolute_time` units.
    var hostTime: UInt64
    var source: AudioSource
}

enum MeetingAudioFormat {
    static let sampleRate = 16_000
    static let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: Double(sampleRate),
        channels: 1,
        interleaved: false
    )!

    /// Seconds between two host times.
    static func seconds(from start: UInt64, to time: UInt64) -> TimeInterval {
        let a = AudioConvertHostTimeToNanos(start)
        let b = AudioConvertHostTimeToNanos(time)
        return (Double(b) - Double(a)) / 1_000_000_000
    }

    static var now: UInt64 { AudioGetCurrentHostTime() }

    /// Host time `duration` seconds before `time`.
    static func hostTime(_ time: UInt64, minus duration: TimeInterval) -> UInt64 {
        let nanos = AudioConvertHostTimeToNanos(time)
        let delta = UInt64(max(0, duration) * 1_000_000_000)
        return AudioConvertNanosToHostTime(nanos > delta ? nanos - delta : 0)
    }
}

/// Converts any PCM buffer to 16 kHz mono Float32. Streaming: the converter keeps its
/// resampler history between calls, so consecutive buffers join without clicks.
///
/// Not thread-safe: each capture thread owns its own, and only that thread calls
/// `convert` (hence the unchecked conformance, needed to hand it to a tap block).
final class PCMConverter: @unchecked Sendable {
    private let converter: AVAudioConverter?
    private let inputFormat: AVAudioFormat

    init?(from inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else { return nil }
        self.inputFormat = inputFormat
        if inputFormat == MeetingAudioFormat.format {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: inputFormat, to: MeetingAudioFormat.format) else { return nil }
            // Down-mix every channel rather than taking the first one only.
            converter.downmix = true
            self.converter = converter
        }
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard buffer.frameLength > 0 else { return [] }
        guard let converter else {
            guard let data = buffer.floatChannelData?[0] else { return [] }
            return Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        }

        let ratio = MeetingAudioFormat.format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: MeetingAudioFormat.format, frameCapacity: capacity) else {
            return []
        }

        // The input block runs synchronously inside `convert`, on this thread.
        nonisolated(unsafe) let input = buffer
        let supplied = OneShot()
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if supplied.take() {
                // Not `.endOfStream`: that flushes and resets the converter, and the next
                // buffer would no longer join this one. "Nothing more for now" keeps its state.
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0, let data = output.floatChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(start: data, count: Int(output.frameLength)))
    }

    /// Only touched synchronously inside `convert`, on the calling thread.
    private final class OneShot: @unchecked Sendable {
        private var fired = false
        /// The value before this call; then latches to `true`.
        func take() -> Bool {
            defer { fired = true }
            return fired
        }
    }
}
