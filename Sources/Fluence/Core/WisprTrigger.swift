import AppKit
import Carbon.HIToolbox

/// Presses and lets go of Wispr Flow's dictation key with synthetic events, so one
/// compare-mode recording is heard by Wispr too.
///
/// Wispr has no API; its own shortcut is the only handle on it. With it, the comparison
/// window's one Record button gets Apple, Parakeet and Wispr on the same words: no second
/// key to hold, no hunting for Wispr's text afterwards.
///
/// Brittle by nature: it works only while the key below is Wispr's `ptt` shortcut.
@MainActor
enum WisprTrigger {
    /// Left ⌘, Wispr's `ptt` key. If Wispr is rebound, change this to match; Wispr keeps its
    /// key codes in `~/Library/Application Support/Wispr Flow/config.json`
    /// (`prefs.user.shortcuts`).
    private static let pushToTalkKeyCode = CGKeyCode(kVK_Command)

    /// `NX_DEVICELCMDKEYMASK`. `.maskCommand` alone doesn't say which ⌘ is down, and Wispr
    /// listens for the left one specifically.
    private static let leftCommandFlag = CGEventFlags(rawValue: 0x0000_0008)

    private static var isHolding = false

    static func press() {
        guard !isHolding else { return }
        isHolding = true
        post(flags: [.maskCommand, leftCommandFlag])
    }

    static func release() {
        guard isHolding else { return }
        isHolding = false
        post(flags: [])
    }

    /// Built from a bare `CGEvent(source: nil)` with the key code set by hand. Starting from a
    /// keyboard event and retyping it to flags-changed drops the key code without any error,
    /// and Wispr never reacts.
    private static func post(flags: CGEventFlags) {
        guard let event = CGEvent(source: nil) else {
            Log.speech.error("WisprTrigger: could not create the flags-changed event")
            return
        }
        event.type = .flagsChanged
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(pushToTalkKeyCode))
        event.flags = flags
        event.post(tap: .cghidEventTap)
    }
}
