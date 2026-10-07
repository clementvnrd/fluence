import AppKit
import Carbon.HIToolbox
import Foundation

/// A keyboard shortcut combination (at least two keys, e.g. Modifiers + Key, or Double Modifier).
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
        // Custom combo format: combo:<keyCode>:<modifierFlagsRaw>:<isModifierOnly>:<shortName>:<displayName>
        let parts = rawValue.split(separator: ":", omittingEmptySubsequences: false)
        if parts.count >= 6, parts[0] == "combo",
           let kc = Int64(parts[1]),
           let modRaw = UInt64(parts[2]),
           let isModOnly = Bool(String(parts[3])) {
            let sName = String(parts[4])
            let dName = String(parts[5])
            self.init(
                rawValue: rawValue,
                keyCode: kc,
                modifierFlags: CGEventFlags(rawValue: modRaw),
                isModifierOnly: isModOnly,
                displayName: dName,
                shortName: sName,
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

/// Watches for a held modifier key or custom combo using a `CGEventTap`.
@MainActor
final class HotkeyMonitor {
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPressed = false
    private var isCommandPressed = false

    private var isCarbonActive = false
    private var isCommandCarbonActive = false

    /// Whether hotkey monitoring (Carbon or CGEventTap) is currently active and listening.
    var isActive: Bool { isCarbonActive || tap != nil }

    var key: PushToTalkKey = .optionSpace
    var commandKey: PushToTalkKey? = .commandOption
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    var onCommandPress: (() -> Void)?
    var onCommandRelease: (() -> Void)?
    var onLanguageToggle: (() -> Void)?

    /// - Returns: `true` if Carbon or CGEventTap successfully registered.
    @discardableResult
    func start() -> Bool {
        stop()

        // 1. Carbon HIToolbox registration: System-level, ZERO Accessibility permissions required!
        CarbonHotkeyManager.shared.onHotKeyPress = { [weak self] id in
            guard let self else { return }
            if id == 1 {
                self.onPress?()
            } else if id == 2 {
                self.onCommandPress?()
            } else if id == 3 {
                self.onLanguageToggle?()
            }
        }
        CarbonHotkeyManager.shared.onHotKeyRelease = { [weak self] id in
            guard let self else { return }
            if id == 1 {
                self.onRelease?()
            } else if id == 2 {
                self.onCommandRelease?()
            }
        }

        if !key.isModifierOnly && key.keyCode > 0 {
            isCarbonActive = CarbonHotkeyManager.shared.register(
                id: 1,
                keyCode: UInt32(key.keyCode),
                modifierFlags: key.modifierFlags
            )
        }

        if let cmd = commandKey, !cmd.isModifierOnly && cmd.keyCode > 0 && cmd != key {
            isCommandCarbonActive = CarbonHotkeyManager.shared.register(
                id: 2,
                keyCode: UInt32(cmd.keyCode),
                modifierFlags: cmd.modifierFlags
            )
        }

        // Quick Language Toggle: Option + L (kVK_ANSI_L = 37)
        CarbonHotkeyManager.shared.register(
            id: 3,
            keyCode: UInt32(kVK_ANSI_L),
            modifierFlags: .maskAlternate
        )

        // 2. CGEventTap: Allows event swallowing and modifier-only shortcuts when Accessibility is granted
        let mask = (1 << CGEventType.flagsChanged.rawValue)
                 | (1 << CGEventType.keyDown.rawValue)
                 | (1 << CGEventType.keyUp.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(refcon).takeUnretainedValue()

                let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
                let flags = event.flags

                // If Carbon already handles this shortcut, do not double-process
                if monitor.isCarbonActive && !monitor.key.isModifierOnly && keyCode == monitor.key.keyCode {
                    return Unmanaged.passUnretained(event)
                }

                var consume = false
                if Thread.isMainThread {
                    consume = monitor.handle(type: type, keyCode: keyCode, flags: flags)
                } else {
                    Task { @MainActor in
                        _ = monitor.handle(type: type, keyCode: keyCode, flags: flags)
                    }
                }
                return consume ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: refcon
        )

        if let tap {
            self.tap = tap
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
            runLoopSource = source
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            Log.hotkey.notice("CGEventTap not created (Accessibility disabled) — Carbon global hotkey is active: \(self.isCarbonActive)")
        }

        let target = commandKey != nil ? "\(self.key.displayName) & CMD (\(self.commandKey!.displayName))" : self.key.displayName
        Log.hotkey.info("Listening for \(target) [Carbon: \(self.isCarbonActive), CGEventTap: \(self.tap != nil)]")
        return isCarbonActive || (tap != nil)
    }

    func stop() {
        CarbonHotkeyManager.shared.unregisterAll()
        isCarbonActive = false
        isCommandCarbonActive = false

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isPressed = false
        isCommandPressed = false
    }

    // MARK: - Tap callback

    /// - Returns: `true` if the event should be swallowed rather than passed along.
    private func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Bool {
        // The system disables a tap that runs too slowly or is interrupted; re-arm it.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }

        // PTT key combo check
        if checkCombo(key: key, type: type, keyCode: keyCode, flags: flags, isCurrentPressed: &isPressed, onPress: onPress, onRelease: onRelease) {
            return key.shouldConsumeEvent
        }

        // Command mode combo check
        if let commandKey, commandKey != key {
            if checkCombo(key: commandKey, type: type, keyCode: keyCode, flags: flags, isCurrentPressed: &isCommandPressed, onPress: onCommandPress, onRelease: onCommandRelease) {
                return commandKey.shouldConsumeEvent
            }
        }

        return false
    }

    private func checkCombo(
        key: PushToTalkKey,
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        isCurrentPressed: inout Bool,
        onPress: (() -> Void)?,
        onRelease: (() -> Void)?
    ) -> Bool {
        if key.isModifierOnly {
            guard type == .flagsChanged else { return false }
            let nowPressed = flags.contains(key.modifierFlags)
            guard nowPressed != isCurrentPressed else { return false }
            isCurrentPressed = nowPressed
            if nowPressed { onPress?() } else { onRelease?() }
            return true
        } else {
            // Modifier(s) + Key combo (e.g. Option + Space)
            if type == .keyDown {
                guard keyCode == key.keyCode else { return false }
                guard flags.contains(key.modifierFlags) else { return false }
                guard !isCurrentPressed else { return true }
                isCurrentPressed = true
                onPress?()
                return true
            } else if type == .keyUp {
                guard keyCode == key.keyCode else { return false }
                guard isCurrentPressed else { return false }
                isCurrentPressed = false
                onRelease?()
                return true
            } else if type == .flagsChanged {
                // If user releases the modifier while key is still held
                if isCurrentPressed && !flags.contains(key.modifierFlags) {
                    isCurrentPressed = false
                    onRelease?()
                    return false
                }
            }
        }
        return false
    }
}
