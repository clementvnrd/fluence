import AVFoundation
import AudioToolbox
import CoreAudio
import FluenceCore
import Foundation

/// Microphone capture, delivered as mono float32 at the device's own sample rate.
///
/// Capture deliberately knows nothing about the speech engine's format. That is what lets it
/// start the instant the key goes down — before the engine has loaded, before anyone knows
/// which format it wants — so the first word is never clipped. `StreamConverter` turns the
/// chunks into the engine's format later, off the audio thread, in order.
///
/// The mic is open only while a dictation is: no permanent orange dot, nothing listening
/// while idle.
///
/// `start`/`stop` are called from the main thread. The tap runs on a real-time audio thread
/// and touches only the immutable `TapSink` it was installed with.
final class AudioCapture: @unchecked Sendable {
    enum CaptureError: LocalizedError {
        case noInputDevice

        var errorDescription: String? {
            "Aucun micro disponible. Branchez-en un, ou choisissez une entrée dans Réglages Système ▸ Son."
        }
    }

    /// Rebuilt after a configuration change: an engine whose device went away keeps
    /// describing the old one.
    private var engine = AVAudioEngine()
    private var needsRebuild = false
    private var configurationObserver: NSObjectProtocol?
    private var sink: TapSink?
    /// Configuration changes recovered from during this capture. A device that keeps
    /// flapping ends the dictation instead of looping.
    private var recoveries = 0
    private static let maximumRecoveries = 3

    var isRunning: Bool { sink != nil }

    /// The microphone picked in Settings (Clement's picker): a Core Audio device UID, or nil
    /// for the system input. Applied to this engine's input only — the Mac's own default
    /// input is never changed. Read at every start, so a new choice takes effect next hold.
    private var deviceUID: String?

    init() {
        observeConfiguration()
    }

    /// - Parameters:
    ///   - onBuffer: each captured chunk, on the audio thread, in capture order.
    ///   - onLevel: a 0…1 level per chunk, for the meters.
    ///   - onInterrupted: capture ended on its own — the device disappeared, or kept changing.
    ///     Called on the main thread with a reason fit for the user.
    func start(
        deviceUID: String? = nil,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onInterrupted: @escaping @Sendable (String) -> Void
    ) throws {
        guard sink == nil else { return }
        let sink = TapSink(onBuffer: onBuffer, onLevel: onLevel, onInterrupted: onInterrupted)
        recoveries = 0
        if deviceUID != self.deviceUID {
            // A different device: start from a fresh engine rather than re-pointing a
            // running one's input unit.
            self.deviceUID = deviceUID
            needsRebuild = true
        }
        try install(sink)
        self.sink = sink
    }

    func stop() {
        guard sink != nil else { return }
        sink = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        Log.audio.info("capture stopped")
    }

    // MARK: - Engine

    private func install(_ sink: TapSink) throws {
        if needsRebuild { rebuildEngine() }

        let input = engine.inputNode
        selectDevice(on: input)
        let native = input.outputFormat(forBus: 0)

        // With no input device the node reports a 0 Hz, 0-channel format, and installing a
        // tap with it raises an Objective-C exception — which Swift cannot catch, so the
        // whole app would go down. Check first and say what's wrong instead.
        guard native.sampleRate > 0, native.channelCount > 0,
              let mono = AVAudioFormat(
                  commonFormat: .pcmFormatFloat32,
                  sampleRate: native.sampleRate,
                  channels: 1,
                  interleaved: false
              )
        else { throw CaptureError.noInputDevice }

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 2048, format: native, block: Self.tap(into: sink, as: mono))

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        Log.audio.info("""
            capture started — \(native.sampleRate)Hz, \(native.channelCount, privacy: .public) channel(s)
            """)
    }

    /// Points the input node at the chosen microphone. A device that is gone (unplugged
    /// webcam) falls back to the system input rather than failing the dictation.
    private func selectDevice(on input: AVAudioInputNode) {
        guard let uid = deviceUID, uid != "default", !uid.isEmpty else { return }
        guard var device = AudioDevices.deviceID(for: uid), let unit = input.audioUnit else {
            Log.audio.info("chosen microphone unavailable — using the system input")
            return
        }
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Log.audio.error("couldn't select the chosen microphone (\(status, privacy: .public)) — using the system input")
        }
    }

    private func rebuildEngine() {
        engine = AVAudioEngine()
        needsRebuild = false
        observeConfiguration()
    }

    /// AVAudioEngine posts this — and stops itself — when the input device is unplugged,
    /// switched, or changes rate or channel count.
    private func observeConfiguration() {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            self?.configurationChanged()
        }
    }

    private func configurationChanged() {
        needsRebuild = true
        guard let sink else { return } // idle: the next start builds a fresh engine

        // Not inside the notification: AVFoundation says the engine must not be torn down
        // from its own configuration-change handler.
        DispatchQueue.main.async { [weak self] in
            self?.recover(sink)
        }
    }

    /// Picks the capture back up on the new configuration when there still is an input.
    ///
    /// Continuing rather than ending is deliberate: Bluetooth headsets switch profile — and
    /// sample rate — the moment their mic opens, which posts this notification right after
    /// every start. Chunks carry their own format, so the converter downstream follows the
    /// change. Only when no input is left, or the device keeps flapping, does the dictation
    /// end, with what was captured so far.
    private func recover(_ sink: TapSink) {
        guard self.sink === sink else { return } // stopped meanwhile
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()

        recoveries += 1
        do {
            guard recoveries <= Self.maximumRecoveries else {
                throw RecoveryFailure.flapping
            }
            try install(sink)
            Log.audio.info("capture resumed after an audio configuration change")
        } catch {
            self.sink = nil
            Log.audio.error("capture lost: \(error.localizedDescription)")
            sink.onInterrupted(
                (error as? RecoveryFailure) == .flapping
                    ? "Le micro changeait sans cesse : l'enregistrement s'est arrêté."
                    : error.localizedDescription
            )
        }
    }

    private enum RecoveryFailure: Error { case flapping }

    // MARK: - Audio thread

    /// Built in a static context so the block can't inherit any actor isolation: it runs on
    /// the audio thread, and an isolated closure there is a runtime trap.
    private static func tap(into sink: TapSink, as mono: AVAudioFormat) -> AVAudioNodeTapBlock {
        return { buffer, _ in
            guard let chunk = monoCopy(of: buffer, as: mono) else { return }
            sink.onLevel(level(of: chunk))
            sink.onBuffer(AudioChunk(buffer: chunk))
        }
    }

    /// A buffer of our own — AVAudioEngine reuses the tap's buffer as soon as the block
    /// returns — with every live channel mixed down, not just channel 0.
    private static func monoCopy(of buffer: AVAudioPCMBuffer, as mono: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frames = Int(buffer.frameLength)
        guard frames > 0,
              let source = buffer.floatChannelData, // the input node always delivers float32
              let copy = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: buffer.frameLength),
              let destination = copy.floatChannelData?[0]
        else { return nil }
        copy.frameLength = buffer.frameLength

        let count = Int(buffer.format.channelCount)
        let channels: [UnsafePointer<Float>]
        let stride: Int
        if buffer.format.isInterleaved {
            let base = UnsafePointer(source[0])
            channels = (0..<count).map { base + $0 }
            stride = count
        } else {
            channels = (0..<count).map { UnsafePointer(source[$0]) }
            stride = 1
        }
        Downmix.mono(channels: channels, stride: stride, frames: frames, into: destination)
        return copy
    }

    private static func level(of buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0] else { return 0 }
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        var sum: Float = 0
        for i in 0..<count {
            let sample = channel[i]
            sum += sample * sample
        }
        let rms = (sum / Float(count)).squareRoot()

        // Map roughly -50…0 dBFS onto 0…1 so quiet speech still moves the meter.
        let db = 20 * log10(max(rms, 1e-7))
        return max(0, min(1, (db + 50) / 50))
    }
}

/// What a running tap delivers into. Immutable, so the audio thread can share it freely.
private final class TapSink: Sendable {
    let onBuffer: @Sendable (AudioChunk) -> Void
    let onLevel: @Sendable (Float) -> Void
    let onInterrupted: @Sendable (String) -> Void

    init(
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void,
        onInterrupted: @escaping @Sendable (String) -> Void
    ) {
        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.onInterrupted = onInterrupted
    }
}

/// Converts captured audio into the engine's format, statefully and in order.
///
/// One per dictation, used only from that dictation's feed task. Stateful matters: a sample
/// rate converter holds the last few input frames back to filter across the next chunk, so
/// a converter rebuilt per chunk clicks at every boundary, and one never told the stream has
/// ended keeps the tail of the last word. `drain()` is that end-of-stream.
final class StreamConverter {
    let output: AVAudioFormat
    private var converter: AVAudioConverter?
    private var input: AVAudioFormat?

    init(output: AVAudioFormat) {
        self.output = output
    }

    /// - Returns: zero or more buffers in `output` format. Each is freshly allocated, or the
    ///   capture's own copy when no conversion is needed.
    func convert(_ buffer: AVAudioPCMBuffer) -> [AVAudioPCMBuffer] {
        var converted: [AVAudioPCMBuffer] = []
        // The capture can change rate mid-dictation (see `AudioCapture.recover`): finish the
        // old stream before starting a converter for the new one.
        if input != buffer.format {
            converted += drain()
            input = buffer.format
            converter = buffer.format == output ? nil : AVAudioConverter(from: buffer.format, to: output)
        }
        guard let converter else { return converted + [buffer] }
        return converted + run(converter, feeding: buffer)
    }

    /// Flushes whatever the converter is still holding.
    func drain() -> [AVAudioPCMBuffer] {
        defer {
            converter = nil
            input = nil
        }
        guard let converter else { return [] }
        return run(converter, feeding: nil)
    }

    /// - Parameter buffer: nil signals end of stream.
    private func run(_ converter: AVAudioConverter, feeding buffer: AVAudioPCMBuffer?) -> [AVAudioPCMBuffer] {
        let ratio = output.sampleRate / converter.inputFormat.sampleRate
        let frames = Double(max(buffer?.frameLength ?? 0, 1_024))
        let capacity = AVAudioFrameCount((frames * ratio).rounded(.up)) + 64

        nonisolated(unsafe) let input = buffer
        let supplied = Latch()
        var results: [AVAudioPCMBuffer] = []

        // `.haveData` means the output buffer filled up and there may be more, so loop —
        // bounded, in case a converter misbehaves.
        for _ in 0..<64 {
            guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { break }
            var error: NSError?
            let status = converter.convert(to: converted, error: &error) { _, outStatus in
                guard let input else {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard !supplied.take() else {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                outStatus.pointee = .haveData
                return input
            }
            if let error {
                Log.audio.error("conversion failed: \(error.localizedDescription)")
                break
            }
            if converted.frameLength > 0 { results.append(converted) }
            guard status == .haveData else { break }
        }
        return results
    }

    /// One-shot flag. Only touched inside a synchronous `convert` call.
    private final class Latch: @unchecked Sendable {
        private var fired = false
        /// - Returns: the value *before* this call, then latches to `true`.
        func take() -> Bool {
            defer { fired = true }
            return fired
        }
    }
}
