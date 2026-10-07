import Foundation
import Testing

@testable import FluenceCore

struct SpeechGateTests {
    private let rate = 16_000.0

    private func observe(_ gate: inout SpeechGate, seconds: Double, amplitude: Float, chunk: Int = 1_000) {
        let total = Int(seconds * rate)
        var produced = 0
        while produced < total {
            let count = min(chunk, total - produced)
            let samples = (0..<count).map { index in
                amplitude * sin(Float(produced + index) * 2 * .pi * 220 / Float(rate))
            }
            samples.withUnsafeBufferPointer { gate.observe($0, sampleRate: rate) }
            produced += count
        }
    }

    @Test func tapIsTooShort() {
        var gate = SpeechGate()
        observe(&gate, seconds: 0.15, amplitude: 0.3)
        guard case .tooShort = gate.verdict else {
            Issue.record("a 150 ms hold must not be transcribed")
            return
        }
    }

    @Test func roomToneIsSilent() {
        var gate = SpeechGate()
        observe(&gate, seconds: 2, amplitude: 0.0005) // about -69 dBFS RMS
        #expect(gate.verdict == .silent)
        #expect(!gate.hasSpeech)
    }

    @Test func quietSpeechIsAccepted() {
        var gate = SpeechGate()
        observe(&gate, seconds: 0.5, amplitude: 0.0005)
        observe(&gate, seconds: 0.3, amplitude: 0.01) // about -43 dBFS: soft, distant speech
        #expect(gate.verdict == .accepted)
    }

    @Test func opensOnFirstSpeechAcrossOddBufferSizes() {
        var gate = SpeechGate()
        observe(&gate, seconds: 0.4, amplitude: 0.0005, chunk: 333)
        #expect(!gate.hasSpeech)
        observe(&gate, seconds: 0.1, amplitude: 0.1, chunk: 333)
        #expect(gate.hasSpeech)
        #expect(abs(gate.duration - 0.5) < 0.001)
    }
}

struct DownmixTests {
    private func mix(_ channels: [[Float]]) -> [Float] {
        let frames = channels[0].count
        var output = [Float](repeating: .nan, count: frames)
        let pointers = channels.map { channel -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: frames)
            pointer.initialize(from: channel, count: frames)
            return pointer
        }
        defer { pointers.forEach { $0.deallocate() } }
        output.withUnsafeMutableBufferPointer { buffer in
            Downmix.mono(channels: pointers.map { UnsafePointer($0) }, stride: 1, frames: frames, into: buffer.baseAddress!)
        }
        return output
    }

    @Test func voiceOnASecondInputSurvivesAtFullLevel() {
        let voice: [Float] = [0.5, -0.5, 0.25, -0.25]
        let dead = [Float](repeating: 0, count: 4)
        #expect(mix([dead, voice, dead, dead, dead, dead, dead, dead]) == voice)
    }

    @Test func liveChannelsAreAveraged() {
        #expect(mix([[0.4, 0.2], [0.2, 0.4]]) == [0.3, 0.3].map { Float($0) })
    }

    @Test func noiseFloorChannelsAreLeftOut() {
        let voice: [Float] = [0.5, -0.5, 0.5, -0.5]
        let hiss: [Float] = [0.0001, -0.0001, 0.0001, -0.0001]
        #expect(mix([hiss, voice]) == voice)
    }

    @Test func allSilentIsSilent() {
        #expect(mix([[0, 0], [0, 0]]) == [0, 0])
    }

    @Test func interleavedStride() {
        // L R L R: voice on the right only.
        let interleaved: [Float] = [0, 0.5, 0, -0.5]
        var output = [Float](repeating: .nan, count: 2)
        interleaved.withUnsafeBufferPointer { source in
            let base = source.baseAddress!
            output.withUnsafeMutableBufferPointer { buffer in
                Downmix.mono(channels: [base, base + 1], stride: 2, frames: 2, into: buffer.baseAddress!)
            }
        }
        #expect(output == [0.5, -0.5])
    }
}
