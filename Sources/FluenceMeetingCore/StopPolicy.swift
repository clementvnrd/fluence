import Foundation

/// Why a recording ended. Kept on the controller for the UI ("Stopped: call ended").
public enum StopReason: String, Sendable, Codable {
    case user
    case callEnded
    case silence
    case maxDuration
    /// No longer used to stop (FLU-32: a locked screen keeps recording); kept so a stored
    /// value still decodes.
    case screenLocked
    case systemSleep
    /// Another user took the Mac (fast user switching).
    case userSwitched
    case captureFailed
    /// Fluence was quitting (FLU-54): stopped and saved first.
    case appQuit

    public var explanation: String {
        switch self {
        case .user: "Stopped"
        case .callEnded: "Call ended"
        case .silence: "Stopped after 10 minutes of silence"
        case .maxDuration: "Reached the maximum meeting length"
        case .screenLocked: "Stopped: screen locked"
        case .systemSleep: "Stopped: Mac going to sleep"
        case .userSwitched: "Stopped: another user took the Mac"
        case .captureFailed: "Stopped: audio capture failed"
        case .appQuit: "Stopped: Fluence quit"
        }
    }
}

/// Something the Mac did while a meeting records.
public enum SystemEvent: Sendable, Equatable {
    case screenLocked
    case displaySlept
    case systemWillSleep
    case userSwitchedOut
}

/// The automatic stop conditions that depend only on elapsed times. Event-driven ones
/// (Stop button, system events) are decided by `reason(for:)`.
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

    /// FLU-32: a call goes on behind a locked or dark screen (an audio-only call, a phone
    /// on the desk), so those keep recording; the app holds off idle sleep meanwhile. Real
    /// sleep and another user taking the Mac end the capture, so the meeting is stopped and
    /// saved first.
    public static func reason(for event: SystemEvent) -> StopReason? {
        switch event {
        case .screenLocked, .displaySlept: nil
        case .systemWillSleep: .systemSleep
        case .userSwitchedOut: .userSwitched
        }
    }

    /// After an automatic stop the call may still be going on: it is offered again. After
    /// the user's own stop it is not, until the app leaves the microphone.
    public static func offersAgain(after reason: StopReason) -> Bool {
        reason != .user
    }
}
