import AppKit
import Carbon.HIToolbox
import FluenceCore
import Foundation

/// Which modifier key holds the mic open.
enum PushToTalkKey: String, CaseIterable, Sendable {
    case rightOption
    case fn
    case rightCommand

    var keyCode: Int64 {
        switch self {
        case .rightOption: Int64(kVK_RightOption)   // 61
        case .fn: Int64(kVK_Function)               // 63
        case .rightCommand: Int64(kVK_RightCommand) // 54
        }
    }

    /// Device-*dependent* bit for this specific physical key.
    ///
    /// `CGEventFlags.maskAlternate` is the union mask — it's set whenever *either* Option
    /// key is down. Using it means: hold Left ⌥, tap Right ⌥, and the release is invisible
    /// (the union bit is still set by the left key), so `onRelease` never fires. The mic
    /// stays open, the HUD stays up, and the next press is swallowed too.
    ///
    /// These raw values are the NX_DEVICE* masks from IOKit's event system; they carry the
    /// left/right distinction that the public `CGEventFlags` constants discard.
    var flag: CGEventFlags {
        switch self {
        case .rightOption: CGEventFlags(rawValue: 0x40)   // NX_DEVICERALTKEYMASK
        case .rightCommand: CGEventFlags(rawValue: 0x10)  // NX_DEVICERCMDKEYMASK
        case .fn: .maskSecondaryFn                        // no left/right variant exists
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: "Right ⌥"
        case .fn: "fn"
        case .rightCommand: "Right ⌘"
        }
    }

    /// Swallowing `fn` would break fn+arrow, fn+delete and the emoji picker, so we let it
    /// through. Dedicated right-hand modifiers are safe to consume.
    var shouldConsumeEvent: Bool { self != .fn }
}

// MARK: FLU-5 input

/// The modifier that, held with the push-to-talk key, turns the hold into a Command Mode
/// instruction ("make this more formal") instead of dictation.
///
/// Control by default, as in Wispr Flow (fn + Control). It is never consumed and never
/// conflicts with a push-to-talk choice: those are Right ⌥, fn and Right ⌘.
enum CommandModifier: String, CaseIterable, Sendable {
    case control
    case shift
    case off

    /// The union mask: either Control key will do, which is what a user means by "Control".
    var flag: CGEventFlags? {
        switch self {
        case .control: .maskControl
        case .shift: .maskShift
        case .off: nil
        }
    }

    func isHeld(in flags: CGEventFlags) -> Bool {
        flag.map(flags.contains) ?? false
    }

    var displayName: String {
        switch self {
        case .control: "Control ⌃"
        case .shift: "Shift ⇧"
        case .off: "Off"
        }
    }
}

/// ⌃⌘V and ⌃⌘C: paste or copy the last transcript.
enum LastTranscriptAction: Sendable {
    case paste
    case copy
}

// MARK: end FLU-5 input

/// Watches the push-to-talk key, and the few chords Fluence answers to, with a `CGEventTap`.
///
/// A tap is required rather than `NSEvent.addGlobalMonitor` because `fn` and left/right
/// modifier discrimination don't surface through the higher-level APIs, and because a global
/// monitor can only watch: the Space of a PTT+Space chord, an Esc that cancels a dictation and
/// ⌃⌘V must not also reach the app underneath. This needs Accessibility permission; without
/// it `CGEvent.tapCreate` returns nil.
///
/// What the key *means* — hold, double-tap, hands-free, Command Mode — is decided by
/// `PushToTalkGesture` in FluenceCore; this class only feeds it events and swallows what it
/// must. Every key event on the session passes through here, on the main thread, so the
/// path for keys Fluence ignores is a handful of comparisons and nothing else.
@MainActor
final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false

    var key: PushToTalkKey = .rightOption
    /// What each gesture asks the controller to do.
    var onGesture: ((PushToTalkGesture.Action) -> Void)?
    /// The system disabled the tap. Events were missed while it was off — possibly the
    /// key-up of the hold in progress.
    var onTapDisabled: (() -> Void)?

    // MARK: FLU-5 input
    var commandModifier: CommandModifier = .control
    /// Esc was pressed. Returns whether it cancelled something: only then is it swallowed,
    /// so Esc keeps closing dialogs and leaving fields whenever Fluence is idle.
    var onEscape: (() -> Bool)?
    /// ⌃⌘V or ⌃⌘C. Nil when the shortcuts are switched off, so the chords pass through.
    var onLastTranscript: ((LastTranscriptAction) -> Void)?

    private var gesture = PushToTalkGesture()
    private var windowTimer: Task<Void, Never>?
    /// Keys whose key-down was swallowed. Their auto-repeats and key-up are swallowed too: an
    /// app that sees a key-up (or a repeat) without its key-down can act on it.
    private var swallowed: Set<Int64> = []
    // MARK: end FLU-5 input

    /// - Returns: `false` if the tap couldn't be created — almost always missing Accessibility permission.
    @discardableResult
    func start() -> Bool {
        stop()

        let mask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                // The tap's source is added to the *main* run loop (`CFRunLoopGetMain`, not
                // "current"), so this runs on the main thread — and the check below makes
                // that a guarantee rather than an assumption: `assumeIsolated` traps instead
                // of checking, and the answer is needed synchronously, so hopping isn't an
                // option. Off the main thread, the event passes through untouched.
                guard Thread.isMainThread else { return Unmanaged.passUnretained(event) }

                // CGEvent isn't Sendable, so pull out the plain values before crossing into
                // actor-isolated code.
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let flags = event.flags
                let consume = MainActor.assumeIsolated {
                    monitor.handle(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        ) else {
            Log.hotkey.error("tapCreate failed — Accessibility permission missing?")
            return false
        }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        Log.hotkey.info("listening for \(self.key.displayName)")
        return true
    }

    func stop() {
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isPressed = false
        gesture = PushToTalkGesture()
        windowTimer?.cancel()
        swallowed.removeAll()
    }

    /// The dictation ended without the key saying so (cancelled, failed, the recording
    /// limit, the HUD's Stop key), or the controller declined to start one.
    func sessionEnded() {
        gesture.sessionEnded()
        windowTimer?.cancel()
    }

    // MARK: - Tap callback

    /// - Returns: `true` if the event should be swallowed rather than passed along.
    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        switch type {
        case .flagsChanged:
            return handleFlags(keyCode: keyCode, flags: flags)
        case .keyDown:
            return handleKeyDown(keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        case .keyUp:
            return swallowed.remove(keyCode) != nil
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // The system disables a tap that runs too slowly or is interrupted; re-arm it.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Whatever we believed about the key is stale. Starting from "up" means a key
            // still held is simply ignored until it's pressed again — never mistaken for a
            // press whose release we'll wait on forever.
            isPressed = false
            gesture.tapInterrupted()
            windowTimer?.cancel()
            swallowed.removeAll()
            Log.hotkey.error("event tap was disabled by the system — re-armed")
            onTapDisabled?()
            return false
        default:
            return false
        }
    }

    private func handleFlags(keyCode: Int64, flags: CGEventFlags) -> Bool {
        guard keyCode == key.keyCode else {
            // Another modifier moved. With the push-to-talk key held, it may be the Command
            // Mode modifier joining the hold. Never swallowed: it is the user's modifier.
            if isPressed, commandModifier.isHeld(in: flags) {
                perform(gesture.commandModifierDown())
            }
            return false
        }

        let nowPressed = flags.contains(key.flag)
        guard nowPressed != isPressed else { return false }
        isPressed = nowPressed

        let now = ProcessInfo.processInfo.systemUptime
        perform(nowPressed
            ? gesture.keyDown(at: now, commandModifier: commandModifier.isHeld(in: flags))
            : gesture.keyUp(at: now))

        return key.shouldConsumeEvent
    }

    // MARK: FLU-5 input

    private func handleKeyDown(keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        // Auto-repeat of a key whose first key-down we swallowed.
        if swallowed.contains(keyCode) { return true }

        // PTT + Space: hands-free. Only while the push-to-talk key is held, so Space is
        // never touched otherwise.
        if keyCode == Int64(kVK_Space), isPressed {
            let (consume, actions) = gesture.space()
            perform(actions)
            if consume { swallowed.insert(keyCode) }
            return consume
        }

        if keyCode == Int64(kVK_Escape), !isRepeat, onEscape?() == true {
            swallowed.insert(keyCode)
            return true
        }

        // ⌃⌘V / ⌃⌘C, exactly: Shift or Option held makes it someone else's shortcut.
        let chord = flags.intersection([.maskCommand, .maskControl, .maskShift, .maskAlternate])
        if chord == [.maskCommand, .maskControl], let onLastTranscript {
            let action: LastTranscriptAction? = switch keyCode {
            // Matched by the letter the layout types, not by position: on Dvorak the key
            // in QWERTY's V position types K.
            case Int64(TextInjector.keyCode(producing: "v") ?? CGKeyCode(kVK_ANSI_V)): .paste
            case Int64(TextInjector.keyCode(producing: "c") ?? CGKeyCode(kVK_ANSI_C)): .copy
            default: nil
            }
            if let action {
                swallowed.insert(keyCode)
                if !isRepeat { onLastTranscript(action) }
                return true
            }
        }
        return false
    }

    /// Hands the gesture's actions to the controller, then arms the double-tap window's
    /// timer if a tap just opened one.
    private func perform(_ actions: [PushToTalkGesture.Action]) {
        for action in actions { onGesture?(action) }
        guard case .tapped(let tappedAt) = gesture.phase, let deadline = gesture.tapDeadline else { return }
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        windowTimer?.cancel()
        windowTimer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.perform(self.gesture.windowElapsed(tappedAt: tappedAt))
        }
    }
    // MARK: end FLU-5 input
}
