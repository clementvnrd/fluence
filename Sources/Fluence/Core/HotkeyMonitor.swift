import AppKit
import Carbon.HIToolbox
import FluenceCore
import Foundation

/// A keyboard shortcut combination (at least two keys, e.g. Modifiers + Key, or Double Modifier).
///
/// Clement's model (FLU-11): presets like ⌥ Espace or ⌃ ⌥, and any combination recorded in
/// Settings. A combination with a key is registered with Carbon, which needs no
/// Accessibility grant; a modifier-only one is watched by the event tap.
struct PushToTalkKey: RawRepresentable, CaseIterable, Hashable, Sendable, Identifiable {
    let rawValue: String
    var id: String { rawValue }

    let keyCode: Int64
    let modifierFlags: CGEventFlags
    let isModifierOnly: Bool
    let displayName: String
    let shortName: String
    let shouldConsumeEvent: Bool

    init(
        rawValue: String,
        keyCode: Int64 = 0,
        modifierFlags: CGEventFlags = [],
        isModifierOnly: Bool = false,
        displayName: String,
        shortName: String,
        shouldConsumeEvent: Bool = true
    ) {
        self.rawValue = rawValue
        self.keyCode = keyCode
        self.modifierFlags = modifierFlags
        self.isModifierOnly = isModifierOnly
        self.displayName = displayName
        self.shortName = shortName
        self.shouldConsumeEvent = shouldConsumeEvent
    }

    init?(rawValue: String) {
        if let preset = Self.presetsByRawValue[rawValue] {
            self = preset
            return
        }
        // Custom combo format: combo:<keyCode>:<modifierFlagsRaw>:<isModifierOnly>:<shortName>:<displayName>.
        // Parsed with bounds (R13): a key code outside 16 bits used to reach `UInt32(keyCode)`
        // and crash every launch.
        if let combo = ShortcutCombo(rawValue: rawValue) {
            self.init(
                rawValue: rawValue,
                keyCode: Int64(combo.keyCode),
                modifierFlags: CGEventFlags(rawValue: combo.modifierFlags),
                isModifierOnly: combo.isModifierOnly,
                displayName: combo.displayName,
                shortName: combo.shortName,
                shouldConsumeEvent: true
            )
            return
        }
        // Backward compatibility for legacy raw values
        switch rawValue {
        case "rightOption", "leftOption", "space":
            self = .optionSpace
        case "fn":
            self = .controlOption
        case "rightCommand", "leftCommand":
            self = .commandOption
        case "rightControl", "leftControl":
            self = .controlSpace
        default:
            return nil
        }
    }

    // MARK: - Standard Multi-Key Presets (At least 2 keys)

    /// Option + Espace (⌥␣) — Standard Mac dictation shortcut
    static let optionSpace = PushToTalkKey(
        rawValue: "optionSpace",
        keyCode: Int64(kVK_Space), // 49
        modifierFlags: .maskAlternate,
        isModifierOnly: false,
        displayName: "Option + Espace (⌥␣)",
        shortName: "⌥ Espace"
    )

    /// Contrôle + Espace (⌃␣)
    static let controlSpace = PushToTalkKey(
        rawValue: "controlSpace",
        keyCode: Int64(kVK_Space), // 49
        modifierFlags: .maskControl,
        isModifierOnly: false,
        displayName: "Contrôle + Espace (⌃␣)",
        shortName: "⌃ Espace"
    )

    /// Contrôle + Option (⌃⌥) — Double modifier hold (Wispr Flow style)
    static let controlOption = PushToTalkKey(
        rawValue: "controlOption",
        keyCode: 0,
        modifierFlags: [.maskControl, .maskAlternate],
        isModifierOnly: true,
        displayName: "Contrôle + Option (⌃⌥)",
        shortName: "⌃ ⌥"
    )

    /// Commande + Option (⌘⌥)
    static let commandOption = PushToTalkKey(
        rawValue: "commandOption",
        keyCode: 0,
        modifierFlags: [.maskCommand, .maskAlternate],
        isModifierOnly: true,
        displayName: "Commande + Option (⌘⌥)",
        shortName: "⌘ ⌥"
    )

    /// Option + D (⌥D) — D pour Dictée
    static let optionD = PushToTalkKey(
        rawValue: "optionD",
        keyCode: Int64(kVK_ANSI_D), // 2
        modifierFlags: .maskAlternate,
        isModifierOnly: false,
        displayName: "Option + D (⌥D)",
        shortName: "⌥ D"
    )

    /// Contrôle + D (⌃D)
    static let controlD = PushToTalkKey(
        rawValue: "controlD",
        keyCode: Int64(kVK_ANSI_D), // 2
        modifierFlags: .maskControl,
        isModifierOnly: false,
        displayName: "Contrôle + D (⌃D)",
        shortName: "⌃ D"
    )

    /// Commande + Maj + Espace (⌘⇧␣)
    static let commandShiftSpace = PushToTalkKey(
        rawValue: "commandShiftSpace",
        keyCode: Int64(kVK_Space), // 49
        modifierFlags: [.maskCommand, .maskShift],
        isModifierOnly: false,
        displayName: "Commande + Maj + Espace (⌘⇧␣)",
        shortName: "⌘ ⇧ Espace"
    )

    /// Contrôle + Option + Espace (⌃⌥␣)
    static let controlOptionSpace = PushToTalkKey(
        rawValue: "controlOptionSpace",
        keyCode: Int64(kVK_Space), // 49
        modifierFlags: [.maskControl, .maskAlternate],
        isModifierOnly: false,
        displayName: "Contrôle + Option + Espace (⌃⌥␣)",
        shortName: "⌃ ⌥ Espace"
    )

    static let allCases: [PushToTalkKey] = [
        .optionSpace,
        .controlSpace,
        .controlOption,
        .commandOption,
        .optionD,
        .controlD,
        .commandShiftSpace,
        .controlOptionSpace
    ]

    private static let presetsByRawValue: [String: PushToTalkKey] = Dictionary(
        uniqueKeysWithValues: allCases.map { ($0.rawValue, $0) }
    )

    /// Builds a combination from an AppKit event, requiring AT LEAST two keys.
    /// Returns nil if fewer than 2 keys are pressed.
    static func comboFrom(event: NSEvent) -> PushToTalkKey? {
        var mods: CGEventFlags = []
        var modSymbols: [String] = []

        if event.modifierFlags.contains(.control) {
            mods.insert(.maskControl)
            modSymbols.append("⌃")
        }
        if event.modifierFlags.contains(.option) {
            mods.insert(.maskAlternate)
            modSymbols.append("⌥")
        }
        if event.modifierFlags.contains(.command) {
            mods.insert(.maskCommand)
            modSymbols.append("⌘")
        }
        if event.modifierFlags.contains(.shift) {
            mods.insert(.maskShift)
            modSymbols.append("⇧")
        }

        if event.type == .flagsChanged {
            // Must have at least 2 modifier keys held simultaneously (e.g. Control + Option)
            guard modSymbols.count >= 2 else { return nil }
            let sName = modSymbols.joined(separator: " ")
            let dName = "\(sName) (Modificateurs)"
            let raw = "combo:0:\(mods.rawValue):true:\(sName):\(dName)"
            return PushToTalkKey(
                rawValue: raw,
                keyCode: 0,
                modifierFlags: mods,
                isModifierOnly: true,
                displayName: dName,
                shortName: sName
            )
        } else if event.type == .keyDown {
            // Must have at least 1 modifier + 1 key (e.g. Option + Space, Control + D) = 2 keys!
            guard !mods.isEmpty else { return nil }
            let keyCode = Int64(event.keyCode)
            let keyStr = keyName(for: event)
            let sName = "\(modSymbols.joined(separator: " ")) \(keyStr)"
            let dName = "\(sName) (\(keyStr))"
            let raw = "combo:\(keyCode):\(mods.rawValue):false:\(sName):\(dName)"
            return PushToTalkKey(
                rawValue: raw,
                keyCode: keyCode,
                modifierFlags: mods,
                isModifierOnly: false,
                displayName: dName,
                shortName: sName
            )
        }
        return nil
    }

    private static func keyName(for event: NSEvent) -> String {
        switch Int(event.keyCode) {
        case kVK_Space: return "Espace"
        case kVK_Return: return "Entrée"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Échap"
        case kVK_Delete: return "Suppr"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default:
            if let chars = event.charactersIgnoringModifiers, !chars.isEmpty {
                let first = chars.prefix(1)
                if first == " " { return "Espace" }
                return first.uppercased()
            }
            return "Touche \(event.keyCode)"
        }
    }
}

/// ⌃⌘V and ⌃⌘C: paste or copy the last transcript.
enum LastTranscriptAction: Sendable {
    case paste
    case copy
}

/// Watches the push-to-talk and Command Mode shortcuts, ⌥L, and the few chords Fluence
/// answers to.
///
/// Two mechanisms, as in Clement's build:
/// - **Carbon** (`RegisterEventHotKey`) for a shortcut with a key (⌥ Espace): works without
///   the Accessibility grant, so dictation starts the moment the app runs.
/// - **A `CGEventTap`** for modifier-only shortcuts (⌃ ⌥), and for what only a tap can do:
///   swallow Esc while cancelling a dictation, ⌃⌘V / ⌃⌘C, and PTT + Space. It needs
///   Accessibility; without it `CGEvent.tapCreate` returns nil and Carbon still works.
///
/// What a press *means* — hold, tap to lock, hands-free, Command Mode — is decided by
/// `PushToTalkGesture` in FluenceCore; this class only feeds it events.
@MainActor
final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Which shortcut is physically down, if any.
    private var isPressed = false
    private var isCommandPressed = false

    private var isCarbonActive = false
    private var isCommandCarbonActive = false

    /// Whether any listening mechanism (Carbon or the event tap) is armed.
    var isActive: Bool { isCarbonActive || tap != nil }
    /// Whether the event tap is armed — Esc, ⌃⌘V/⌃⌘C and modifier-only shortcuts need it.
    var hasEventTap: Bool { tap != nil }

    var key: PushToTalkKey = .optionSpace
    /// Nil when Command Mode is off.
    var commandKey: PushToTalkKey?

    /// What each gesture asks the controller to do.
    var onGesture: ((PushToTalkGesture.Action) -> Void)?
    /// ⌥L: Français ⇄ English (⇄ Auto with Whisper).
    var onLanguageToggle: (() -> Void)?
    /// The system disabled the tap. Events were missed while it was off — possibly the
    /// key-up of the hold in progress.
    var onTapDisabled: (() -> Void)?
    /// Esc was pressed. Returns whether it cancelled something: only then is it swallowed,
    /// so Esc keeps closing dialogs and leaving fields whenever Fluence is idle.
    var onEscape: (() -> Bool)?
    /// ⌃⌘V or ⌃⌘C. Nil when the shortcuts are switched off, so the chords pass through.
    var onLastTranscript: ((LastTranscriptAction) -> Void)?

    /// Clement's tap-to-lock: one short tap keeps recording until the next press.
    private var gesture = PushToTalkGesture(tapLocks: true)
    private var windowTimer: Task<Void, Never>?
    /// Keys whose key-down was swallowed. Their auto-repeats and key-up are swallowed too: an
    /// app that sees a key-up (or a repeat) without its key-down can act on it.
    private var swallowed: Set<Int64> = []

    private enum CarbonID {
        static let pushToTalk: UInt32 = 1
        static let command: UInt32 = 2
        static let languageToggle: UInt32 = 3
    }

    /// - Returns: `true` if Carbon or the event tap is listening.
    @discardableResult
    func start() -> Bool {
        stop() // from a clean slate: no duplicate Carbon hotkeys, no stale tap

        let carbon = CarbonHotkeyManager.shared
        carbon.onHotKeyPress = { [weak self] id in self?.carbonEvent(id: id, isDown: true) }
        carbon.onHotKeyRelease = { [weak self] id in self?.carbonEvent(id: id, isDown: false) }

        if !key.isModifierOnly, key.keyCode > 0, let code = UInt32(exactly: key.keyCode) {
            isCarbonActive = carbon.register(
                id: CarbonID.pushToTalk,
                keyCode: code,
                modifierFlags: key.modifierFlags
            )
        }
        if let commandKey, !commandKey.isModifierOnly, commandKey.keyCode > 0, commandKey != key,
           let code = UInt32(exactly: commandKey.keyCode) {
            isCommandCarbonActive = carbon.register(
                id: CarbonID.command,
                keyCode: code,
                modifierFlags: commandKey.modifierFlags
            )
        }
        // Quick language switch: Option + L.
        carbon.register(id: CarbonID.languageToggle, keyCode: UInt32(kVK_ANSI_L), modifierFlags: .maskAlternate)

        installTap()

        Log.hotkey.info("""
            listening for \(self.key.displayName, privacy: .public) \
            [Carbon: \(self.isCarbonActive, privacy: .public), tap: \(self.tap != nil, privacy: .public)]
            """)
        return isActive
    }

    func stop() {
        CarbonHotkeyManager.shared.unregisterAll()
        isCarbonActive = false
        isCommandCarbonActive = false

        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isPressed = false
        isCommandPressed = false
        gesture = PushToTalkGesture(tapLocks: true)
        windowTimer?.cancel()
        swallowed.removeAll()
    }

    /// The dictation ended without the key saying so (cancelled, failed, the recording
    /// limit, the HUD's button), or the controller declined to start one.
    func sessionEnded() {
        gesture.sessionEnded()
        windowTimer?.cancel()
    }

    // MARK: - Carbon

    private func carbonEvent(id: UInt32, isDown: Bool) {
        switch id {
        case CarbonID.pushToTalk:
            shortcut(isDown: isDown, command: false)
        case CarbonID.command:
            shortcut(isDown: isDown, command: true)
        case CarbonID.languageToggle:
            if isDown { onLanguageToggle?() }
        default:
            break
        }
    }

    /// One edge of either shortcut, from Carbon or the tap.
    private func shortcut(isDown: Bool, command: Bool) {
        if command {
            guard isDown != isCommandPressed else { return }
            isCommandPressed = isDown
        } else {
            guard isDown != isPressed else { return }
            isPressed = isDown
        }
        let now = ProcessInfo.processInfo.systemUptime
        perform(isDown ? gesture.keyDown(at: now, commandModifier: command) : gesture.keyUp(at: now))
    }

    // MARK: - Event tap

    private func installTap() {
        let eventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        // `userInfo` is how the C callback gets back to us. Unretained, which is fine only
        // while the monitor lives as long as the app.
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap, // not listen-only, so the callback may drop an event
            eventsOfInterest: CGEventMask(eventMask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()

                // The tap's source is added to the *main* run loop (`CFRunLoopGetMain`, not
                // "current"), so this runs on the main thread — and the check below makes
                // that a guarantee rather than an assumption: `assumeIsolated` traps instead
                // of checking, and the answer is needed synchronously, so hopping isn't an
                // option. Off the main thread, the event passes through untouched.
                guard Thread.isMainThread else { return Unmanaged.passUnretained(event) }

                // Plain values only: `CGEvent` isn't `Sendable`, so it can't be taken into
                // actor-isolated code.
                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
                let flags = event.flags
                let swallow = MainActor.assumeIsolated {
                    monitor.handle(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat)
                }
                return swallow ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            Log.hotkey.notice("tapCreate failed — Accessibility not granted; Carbon shortcuts only")
            return
        }

        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// `true` drops the event; `false` lets it reach the app.
    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        switch type {
        case .flagsChanged:
            return handleFlags(flags: flags)
        case .keyDown:
            return handleKeyDown(keyCode: keyCode, flags: flags, isRepeat: isRepeat)
        case .keyUp:
            if swallowed.remove(keyCode) != nil { return true }
            return handleKeyUp(keyCode: keyCode)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS switched the tap off (a timeout, or user input): turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            // Whatever we believed about the keys is stale. Starting from "up" means a key
            // still held is simply ignored until it's pressed again — never mistaken for a
            // press whose release we'll wait on forever.
            isPressed = false
            isCommandPressed = false
            gesture.tapInterrupted()
            windowTimer?.cancel()
            swallowed.removeAll()
            Log.hotkey.error("event tap was disabled by the system — re-armed")
            Diagnostics.recovery("hotkey.eventTap.rearmed")
            onTapDisabled?()
            return false
        default:
            return false
        }
    }

    /// Shortcuts this tap watches itself: modifier-only ones always, combinations with a key
    /// only when Carbon couldn't register them.
    private func tapWatches(_ shortcut: PushToTalkKey, carbon: Bool) -> Bool {
        shortcut.isModifierOnly || !carbon
    }

    private func handleFlags(flags: CGEventFlags) -> Bool {
        let consumed = false
        for (shortcut, command) in watched() {
            let held = command ? isCommandPressed : isPressed
            if shortcut.isModifierOnly {
                let nowHeld = flags.contains(shortcut.modifierFlags)
                guard nowHeld != held else { continue }
                self.shortcut(isDown: nowHeld, command: command)
                // Never swallowed: they are the user's modifiers, and a swallowed modifier
                // release leaves the app underneath believing it is still held.
            } else if held, !flags.contains(shortcut.modifierFlags) {
                // The modifier came up while the key is still held.
                self.shortcut(isDown: false, command: command)
            }
        }
        return consumed
    }

    private func handleKeyUp(keyCode: Int64) -> Bool {
        for (shortcut, command) in watched() where !shortcut.isModifierOnly && shortcut.keyCode == keyCode {
            let held = command ? isCommandPressed : isPressed
            guard held else { continue }
            self.shortcut(isDown: false, command: command)
            return shortcut.shouldConsumeEvent
        }
        return false
    }

    private func watched() -> [(PushToTalkKey, Bool)] {
        var list: [(PushToTalkKey, Bool)] = []
        if tapWatches(key, carbon: isCarbonActive) { list.append((key, false)) }
        if let commandKey, commandKey != key, tapWatches(commandKey, carbon: isCommandCarbonActive) {
            list.append((commandKey, true))
        }
        return list
    }

    private func handleKeyDown(keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        // Auto-repeat of a key whose first key-down we swallowed.
        if swallowed.contains(keyCode) { return true }

        // A combination Carbon couldn't take, watched here instead.
        for (shortcut, command) in watched() where !shortcut.isModifierOnly && shortcut.keyCode == keyCode {
            guard flags.contains(shortcut.modifierFlags) else { continue }
            if !(command ? isCommandPressed : isPressed) {
                self.shortcut(isDown: true, command: command)
            }
            if shortcut.shouldConsumeEvent { swallowed.insert(keyCode) }
            return shortcut.shouldConsumeEvent
        }

        // PTT + Space: hands-free, for a modifier-only shortcut held down. Only while it is
        // held, so Space is never touched otherwise.
        if keyCode == Int64(kVK_Space), key.isModifierOnly, isPressed {
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
}
