@preconcurrency import AVFoundation
import CoreAudio
import CoreMedia
import Foundation

/// Robust microphone capture using AVCaptureSession, supporting all input devices (USB webcams,
/// built-in mics, Bluetooth headsets, virtual devices) with on-the-fly sample rate conversion.
final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "ai.pivotstudio.murmur-youtube.audiocapture", qos: .userInteractive)

    private nonisolated(unsafe) var converter: AVAudioConverter?
    private nonisolated(unsafe) var inputFormat: AVAudioFormat?
    private nonisolated(unsafe) var outputFormat: AVAudioFormat?
    private nonisolated(unsafe) var isRunning = false

    /// Called on the audio queue with each converted buffer.
    private nonisolated(unsafe) var onBuffer: (@Sendable (AudioChunk) -> Void)?
    /// Called on the audio queue with a 0…1 RMS level, for the HUD waveform.
    private nonisolated(unsafe) var onLevel: (@Sendable (Float) -> Void)?

    func start(
        outputFormat: AVAudioFormat,
        deviceUID: String? = nil,
        onBuffer: @escaping @Sendable (AudioChunk) -> Void,
        onLevel: @escaping @Sendable (Float) -> Void
    ) throws {
        guard !isRunning else { return }

        self.onBuffer = onBuffer
        self.onLevel = onLevel
        self.outputFormat = outputFormat
        self.converter = nil
        self.inputFormat = nil

        session.beginConfiguration()

        // Clear previous inputs/outputs
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }

        // Find requested capture device or fall back to system default
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        let device: AVCaptureDevice?
        if let uid = deviceUID, !uid.isEmpty, uid != "default" {
            device = discovery.devices.first(where: { $0.uniqueID == uid || $0.localizedName == uid })
                ?? AVCaptureDevice.default(for: .audio)
        } else {
            device = AVCaptureDevice.default(for: .audio)
        }

        guard let targetDevice = device else {
            session.commitConfiguration()
            Log.audio.error("no audio capture device available")
            throw TranscriptionError.noAudioFormat
        }

        Log.audio.info("configuring audio capture on: \(targetDevice.localizedName) (UID: \(targetDevice.uniqueID))")

        let input = try AVCaptureDeviceInput(device: targetDevice)
        if session.canAddInput(input) {
            session.addInput(input)
        } else {
            session.commitConfiguration()
            Log.audio.error("cannot add capture device input to session")
            throw TranscriptionError.noAudioFormat
        }

        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) {
            session.addOutput(output)
        } else {
            session.commitConfiguration()
            Log.audio.error("cannot add capture data output to session")
            throw TranscriptionError.noAudioFormat
        }

        session.commitConfiguration()
        session.startRunning()
        isRunning = true
        Log.audio.info("audio capture started on \(targetDevice.localizedName)")
    }

    func stop() {
        guard isRunning else { return }
        session.stopRunning()

        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        session.commitConfiguration()

        isRunning = false
        converter = nil
        inputFormat = nil
        onBuffer = nil
        onLevel = nil
        Log.audio.info("audio capture stopped")
    }

    // MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let outputFormat else { return }

        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              let nativeFormat = AVAudioFormat(streamDescription: asbd)
        else { return }

        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: frameCount)
        else { return }
        pcmBuffer.frameLength = frameCount

        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: pcmBuffer.mutableAudioBufferList
        )
        guard status == noErr else {
            Log.audio.error("CMSampleBufferCopyPCMDataIntoAudioBufferList failed: \(status)")
            return
        }

        // Report RMS on native buffer
        onLevel?(Self.rms(of: pcmBuffer))

        // Check if format conversion is needed
        if nativeFormat == outputFormat {
            onBuffer?(AudioChunk(buffer: pcmBuffer))
            return
        }

        // Setup converter if not cached or if input format changed
        if converter == nil || inputFormat != nativeFormat {
            inputFormat = nativeFormat
            converter = AVAudioConverter(from: nativeFormat, to: outputFormat)
        }

        guard let converter else { return }

        let ratio = outputFormat.sampleRate / nativeFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(pcmBuffer.frameLength) * ratio).rounded(.up)) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return }

        nonisolated(unsafe) let input = pcmBuffer
        let consumed = Latch()
        var error: NSError?
        let convStatus = converter.convert(to: converted, error: &error) { _, outStatus in
            guard !consumed.take() else {
                outStatus.pointee = .noDataNow
                return nil
            }
            outStatus.pointee = .haveData
            return input
        }

        if let error {
            Log.audio.error("audio conversion failed: \(error.localizedDescription)")
            return
        }

        guard convStatus != .error, converted.frameLength > 0 else { return }
        onBuffer?(AudioChunk(buffer: converted))
    }

    // MARK: - Helpers

    private final class Latch: @unchecked Sendable {
        private var fired = false
        func take() -> Bool {
            defer { fired = true }
            return fired
        }
    }

    private static func rms(of buffer: AVAudioPCMBuffer) -> Float {
        let count = Int(buffer.frameLength)
        guard count > 0 else { return 0 }

        if let channel = buffer.floatChannelData?[0] {
            var sum: Float = 0
            for i in 0..<count {
                let sample = channel[i]
                sum += sample * sample
            }
            let rms = (sum / Float(count)).squareRoot()
            let db = 20 * log10(max(rms, 1e-7))
            return max(0, min(1, (db + 50) / 50))
        } else if let channel = buffer.int16ChannelData?[0] {
            var sum: Float = 0
            for i in 0..<count {
                let sample = Float(channel[i]) / 32768.0
                sum += sample * sample
            }
            let rms = (sum / Float(count)).squareRoot()
            let db = 20 * log10(max(rms, 1e-7))
            return max(0, min(1, (db + 50) / 50))
        }
        return 0
    }
}
