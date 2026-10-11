import Testing

@testable import FluenceCore

/// A chosen microphone must not be treated as a broken one (FLU-62).
struct CaptureConfigurationPolicyTests {
    typealias Format = CaptureConfigurationPolicy.Format

    let webcam = Format(sampleRate: 16_000, channelCount: 2)
    let builtIn = Format(sampleRate: 44_100, channelCount: 1)

    @Test("running on the format the tap was installed with: nothing to recover")
    func harmlessNotification() {
        #expect(!CaptureConfigurationPolicy.needsRecovery(isRunning: true, installed: webcam, current: webcam))
    }

    @Test("the device changed rate under the tap: recover")
    func rateChanged() {
        #expect(CaptureConfigurationPolicy.needsRecovery(isRunning: true, installed: builtIn, current: webcam))
        let mono = Format(sampleRate: 16_000, channelCount: 1)
        #expect(CaptureConfigurationPolicy.needsRecovery(isRunning: true, installed: webcam, current: mono))
    }

    @Test("the engine stopped: recover, whatever the format")
    func engineStopped() {
        #expect(CaptureConfigurationPolicy.needsRecovery(isRunning: false, installed: webcam, current: webcam))
    }

    @Test("no tap installed yet: recover")
    func nothingInstalled() {
        #expect(CaptureConfigurationPolicy.needsRecovery(isRunning: true, installed: nil, current: webcam))
    }
}
