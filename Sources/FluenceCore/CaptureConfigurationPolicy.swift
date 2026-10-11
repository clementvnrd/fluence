import Foundation

/// When a configuration-change notification from the audio engine is a real problem (FLU-62).
///
/// Choosing a microphone makes the engine post this notification while it is already running
/// on the format the tap was installed with. Treating every one as a failure rebuilt the engine,
/// which chose the microphone again, which posted it again, until the capture gave up with « le
/// micro changeait sans cesse » and delivered no audio at all.
public enum CaptureConfigurationPolicy {
    public struct Format: Equatable, Sendable {
        public let sampleRate: Double
        public let channelCount: Int

        public init(sampleRate: Double, channelCount: Int) {
            self.sampleRate = sampleRate
            self.channelCount = channelCount
        }
    }

    /// - Parameters:
    ///   - isRunning: the engine is still running after the notification.
    ///   - installed: the format the tap was installed with.
    ///   - current: the input's real format now.
    /// - Returns: true when capture has to be started again: the engine stopped, or the device
    ///   changed rate or channel count under the tap (a Bluetooth headset switching profile).
    public static func needsRecovery(isRunning: Bool, installed: Format?, current: Format) -> Bool {
        guard isRunning, let installed else { return true }
        return installed != current
    }
}
