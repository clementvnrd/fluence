import Foundation

/// Why a recording ended. Kept on the controller for the UI ("Stopped: call ended").
public enum StopReason: String, Sendable, Codable {
    case user
    case callEnded
    case silence
    case maxDuration
    case screenLocked
    case systemSleep
    case captureFailed

    public var explanation: String {
        switch self {
        case .user: "Stopped"
        case .callEnded: "Call ended"
        case .silence: "Stopped after 10 minutes of silence"
        case .maxDuration: "Reached the maximum meeting length"
        case .screenLocked: "Stopped: screen locked"
        case .systemSleep: "Stopped: Mac going to sleep"
        case .captureFailed: "Stopped: audio capture failed"
        }
    }
}

/// The automatic stop conditions that depend only on elapsed times. Event-driven ones
/// (Stop button, screen lock, sleep) are handled by the controller directly.
public struct StopPolicy: Sendable {
    /// The meeting app has stopped using the microphone for this long: the call ended.
    public var callEndedAfter: TimeInterval = 30
    /// No speech on either channel for this long.
    public var silenceLimit: TimeInterval = 600
    public var maxDuration: TimeInterval

    public init(maxDuration: TimeInterval, callEndedAfter: TimeInterval = 30, silenceLimit: TimeInterval = 600) {
        self.maxDuration = maxDuration
        self.callEndedAfter = callEndedAfter
        self.silenceLimit = silenceLimit
    }

    /// All times are seconds since the meeting started.
    /// - Parameters:
    ///   - elapsed: now.
    ///   - lastSpeech: the last time either channel had speech; `nil` = never.
    ///   - appLastUsingMic: the last time the meeting app was seen using the microphone;
    ///     `nil` when there is no app to watch (manual recording), which disables the
    ///     call-ended rule.
    public func reason(
        elapsed: TimeInterval,
        lastSpeech: TimeInterval?,
        appLastUsingMic: TimeInterval?
    ) -> StopReason? {
        if elapsed >= maxDuration { return .maxDuration }
        if let appLastUsingMic, elapsed - appLastUsingMic >= callEndedAfter { return .callEnded }
        if elapsed - (lastSpeech ?? 0) >= silenceLimit { return .silence }
        return nil
    }
}
