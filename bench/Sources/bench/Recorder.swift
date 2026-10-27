@preconcurrency import AVFoundation
import Foundation

// `bench record`: grabs a test clip from the microphone, already at 16 kHz mono, the format
// both engines prefer. Recording in that format up front means neither engine gets an edge
// from a different resampler.

enum MicRecorder {

    static let sampleRate: Double = 16_000

    static func record(to destination: URL) async throws {
        guard await microphoneGranted() else {
            throw BenchFailure("""
                microphone access was denied.
                a swift package command-line tool is not an app bundle, so macOS files the request \
                under the terminal that started it.
                allow your terminal app (Terminal, iTerm, Cursor, VS Code…) in
                System Settings ▸ Privacy & Security ▸ Microphone, then try again.
                """)
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let native = input.outputFormat(forBus: 0)
        guard let wanted = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else {
            throw BenchFailure("could not make a 16 khz mono audio format")
        }

        // On disk: 16-bit little-endian integer PCM, 16 kHz, one channel. AVFoundation picks
        // the container from the extension the user typed (.wav is the documented case).
        let diskSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(
            forWriting: destination, settings: diskSettings, commonFormat: .pcmFormatFloat32, interleaved: false
        )

        let converter: AVAudioConverter?
        if native == wanted {
            converter = nil
        } else {
            guard let made = AVAudioConverter(from: native, to: wanted) else {
                throw BenchFailure("could not convert the microphone format to 16 khz mono")
            }
            converter = made
        }

        let sink = CaptureSink(file: file, converter: converter, target: wanted)
        sink.attach(to: input, format: native)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }

        print("🔴 recording into \(destination.lastPathComponent) — press Return to stop")
        _ = readLine()

        input.removeTap(onBus: 0)
        engine.stop()

        let seconds = Double(sink.framesWritten) / sampleRate
        print("✅ saved \(destination.lastPathComponent) (\(String(format: "%.1f", seconds))s)")
    }

    /// Granted stays granted, an unasked question is asked now, anything else is a no.
    private static func microphoneGranted() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }
}

/// Receives the microphone buffers and writes them to the file.
///
/// Why `@unchecked Sendable`: the tap block runs on a real-time audio thread that Swift
/// concurrency knows nothing about, and `AVAudioFile` / `AVAudioConverter` are not Sendable.
/// The safety argument is by construction instead: once the tap is installed, only that
/// audio thread touches `file`, `converter` and `framesWritten`; the main flow reads
/// `framesWritten` only after `removeTap` and `stop()` have returned, when no callback can
/// still be running.
private final class CaptureSink: @unchecked Sendable {
    private let file: AVAudioFile
    private let converter: AVAudioConverter?
    private let target: AVAudioFormat
    private(set) var framesWritten: AVAudioFramePosition = 0

    init(file: AVAudioFile, converter: AVAudioConverter?, target: AVAudioFormat) {
        self.file = file
        self.converter = converter
        self.target = target
    }

    /// Kept out of any actor on purpose: a block created inside main-actor code would
    /// inherit that isolation and trap when the audio thread calls it.
    nonisolated func attach(to node: AVAudioInputNode, format: AVAudioFormat) {
        node.installTap(onBus: 0, bufferSize: 2048, format: format) { [self] buffer, _ in
            self.take(buffer)
        }
    }

    private func take(_ buffer: AVAudioPCMBuffer) {
        guard let converter else {
            store(buffer)
            return
        }
        // Room for the resampled audio plus a little slack for the converter's own filter.
        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        // Hand over this one buffer, then say "nothing more for now" rather than "finished",
        // so the converter keeps its filter state for the next buffer.
        let feed = OneShotFeed(buffer)
        var failure: NSError?
        let status = converter.convert(to: converted, error: &failure) { _, inputStatus in
            feed.next(inputStatus)
        }
        if status != .error, failure == nil, converted.frameLength > 0 {
            store(converted)
        }
    }

    /// Best effort: a failed write is dropped and the recording goes on.
    private func store(_ buffer: AVAudioPCMBuffer) {
        do {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(buffer.frameLength)
        } catch {
            // ignored on purpose
        }
    }
}

/// Supplies one buffer to an `AVAudioConverter` input block, then reports no data.
/// Unchecked for the same reason as `CaptureSink`: it lives and dies inside one call to
/// `convert`, on the audio thread.
private final class OneShotFeed: @unchecked Sendable {
    private var pending: AVAudioPCMBuffer?

    init(_ buffer: AVAudioPCMBuffer) { pending = buffer }

    func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        guard let buffer = pending else {
            status.pointee = .noDataNow
            return nil
        }
        pending = nil
        status.pointee = .haveData
        return buffer
    }
}
