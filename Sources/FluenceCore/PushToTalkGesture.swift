import Foundation

/// What the push-to-talk key means, as a pure state machine (FLU-5).
///
/// One key carries four gestures, the way Wispr Flow's does:
/// - **hold** to talk, release to type;
/// - **double-tap**, or **key + Space**, to start a hands-free dictation that keeps recording
///   after the key comes up;
/// - a **single tap** to end a hands-free dictation;
/// - the key held **with a modifier** (Command Mode) to speak an instruction instead of text.
///
/// The rules are timing rules, and timing rules are exactly what nobody can check by holding
/// a key and squinting, so they live here, free of the event tap, and are tested directly.
///
/// The first tap of a double-tap already starts a dictation. Rather than wait to see whether
/// a second tap follows — which would delay every ordinary hold by the double-tap window — a
/// press shorter than `tapMaximum` keeps recording for up to `doubleTapWindow` after release:
/// a second press in that window turns the same recording hands-free, no press finishes it.
/// A sub-300 ms press holds no speech worth typing, so the extra tail costs nothing.
public struct PushToTalkGesture: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Open the mic. `command` when the Command Mode modifier was already down.
        case start(command: Bool)
        /// The dictation in progress keeps recording after the key comes up.
        case enterHandsFree
        /// The dictation in progress is a Command Mode instruction, not text to type.
        case markCommand
        /// Stop recording and deliver.
        case finish
    }

    public enum Phase: Equatable, Sendable {
        case idle
        /// Key down, a push-to-talk hold in progress.
        case holding(since: TimeInterval)
        /// Released after a short press; still recording, waiting for a possible second tap.
        case tapped(at: TimeInterval)
        /// Recording hands-free. `keyDown` while the press that started it is still held.
        case handsFree(keyDown: Bool)
        /// The press that ended a hands-free dictation; its release means nothing.
        case stopping
        /// A press the controller is not acting on (it was busy, or the dictation ended
        /// under the key); its release means nothing either.
        case ignoring
    }

    /// A press shorter than this is a tap.
    public static let tapMaximum: TimeInterval = 0.3
    /// With `tapLocks`, Clement's threshold: a press shorter than this locks the recording on.
    public static let lockTapMaximum: TimeInterval = 0.35
    /// The second tap must start within this long after the first one's release.
    public static let doubleTapWindow: TimeInterval = 0.35

    public private(set) var phase: Phase = .idle

    /// Clement's behaviour (FLU-11): a single short tap starts a recording that keeps going
    /// until the next press — no double-tap needed. Off, a tap waits for a second one.
    public var tapLocks: Bool

    public init(tapLocks: Bool = false) {
        self.tapLocks = tapLocks
    }

    /// When the pending double-tap window closes, if one is open.
    public var tapDeadline: TimeInterval? {
        if case .tapped(let at) = phase { return at + Self.doubleTapWindow }
        return nil
    }

    // MARK: - Key events

    public mutating func keyDown(at time: TimeInterval, commandModifier: Bool = false) -> [Action] {
        switch phase {
        case .idle:
            phase = .holding(since: time)
            return [.start(command: commandModifier)]
        case .tapped(let at):
            if time - at <= Self.doubleTapWindow {
                phase = .handsFree(keyDown: true)
                return [.enterHandsFree]
            }
            // The window's timer was late. Finish the stray tap; this press starts nothing,
            // like any press made while a dictation is still finishing.
            phase = .ignoring
            return [.finish]
        case .handsFree(keyDown: false):
            // Ending on the press, not the release: the user is waiting for the text.
            phase = .stopping
            return [.finish]
        case .holding, .handsFree(keyDown: true), .stopping, .ignoring:
            // A second key-down for a key already down.
            return []
        }
    }

    public mutating func keyUp(at time: TimeInterval) -> [Action] {
        switch phase {
        case .holding(let since):
            if tapLocks {
                if time - since < Self.lockTapMaximum {
                    phase = .handsFree(keyDown: false)
                    return [.enterHandsFree]
                }
                phase = .idle
                return [.finish]
            }
            if time - since < Self.tapMaximum {
                phase = .tapped(at: time)
                return []
            }
            phase = .idle
            return [.finish]
        case .handsFree(keyDown: true):
            phase = .handsFree(keyDown: false)
            return []
        case .stopping, .ignoring:
            phase = .idle
            return []
        case .idle, .tapped, .handsFree(keyDown: false):
            return []
        }
    }

    /// Space pressed while the push-to-talk key is down.
    ///
    /// - Returns: whether to swallow the Space, so the chord never types a space into the
    ///   user's document; and what to do.
    public mutating func space() -> (consume: Bool, actions: [Action]) {
        switch phase {
        case .holding:
            phase = .handsFree(keyDown: true)
            return (true, [.enterHandsFree])
        case .handsFree(keyDown: true):
            // Auto-repeat, or a second press of the chord: already hands-free.
            return (true, [])
        case .idle, .tapped, .handsFree(keyDown: false), .stopping, .ignoring:
            return (false, [])
        }
    }

    /// The Command Mode modifier went down while the push-to-talk key is held.
    public mutating func commandModifierDown() -> [Action] {
        if case .holding = phase { return [.markCommand] }
        return []
    }

    /// The double-tap window that opened with the release at `tappedAt` has closed. Keyed
    /// by the release time rather than by a clock reading, so a timer that fires a hair
    /// early (two clocks, rounding) can never leave a recording running.
    public mutating func windowElapsed(tappedAt: TimeInterval) -> [Action] {
        guard phase == .tapped(at: tappedAt) else { return [] }
        phase = .idle
        return [.finish]
    }

    // MARK: - Resynchronisation

    /// The dictation ended without the key saying so — cancelled, failed, hit the recording
    /// limit, stopped from the HUD — or the controller declined to start one. A key still
    /// down must not be read as the next gesture when it comes up.
    public mutating func sessionEnded() {
        switch phase {
        case .holding, .handsFree(keyDown: true), .stopping, .ignoring:
            phase = .ignoring
        case .idle, .tapped, .handsFree(keyDown: false):
            phase = .idle
        }
    }

    /// The event tap was switched off, so key events were missed. A hands-free dictation
    /// does not depend on the key and carries on, waiting for its stopping tap; anything
    /// else starts over from "up".
    public mutating func tapInterrupted() {
        if case .handsFree = phase {
            phase = .handsFree(keyDown: false)
        } else {
            phase = .idle
        }
    }
}
