import AppKit
import Carbon.HIToolbox
import Foundation

/// Manages system-level global hotkeys via Carbon HIToolbox.
///
/// Unlike `CGEventTap`, Carbon's `RegisterEventHotKey` DOES NOT require
/// macOS Accessibility permissions. It registers directly with WindowServer
/// and works immediately out of the box in all applications.
@MainActor
final class CarbonHotkeyManager {
    static let shared = CarbonHotkeyManager()

    private var eventHandlerRef: EventHandlerRef?
    private var registeredHotKeys: [UInt32: EventHotKeyRef] = [:]

    var onHotKeyPress: ((UInt32) -> Void)?
    var onHotKeyRelease: ((UInt32) -> Void)?

    private init() {
        installHandler()
    }

    private func installHandler() {
        guard eventHandlerRef == nil else { return }

        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]

        // Unretained is enough: the manager is the app-wide singleton and outlives the handler.
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            { _, theEvent, userData -> OSStatus in
                guard let theEvent, let userData else { return OSStatus(eventNotHandledErr) }
                let manager = Unmanaged<CarbonHotkeyManager>.fromOpaque(userData).takeUnretainedValue()

                var hotKeyID = EventHotKeyID()
                let paramStatus = GetEventParameter(
                    theEvent,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard paramStatus == noErr else { return OSStatus(eventNotHandledErr) }
                let kind = GetEventKind(theEvent)
                let isPressed = (kind == UInt32(kEventHotKeyPressed))

                Task { @MainActor in
                    manager.handleEvent(id: hotKeyID.id, isPressed: isPressed)
                }
                return noErr
            },
            2,
            &eventTypes,
            refcon,
            &eventHandlerRef
        )

        if status != noErr {
            Log.hotkey.error("Carbon InstallEventHandler failed: \(status)")
            Diagnostics.error("hotkey.carbon.handler", code: Int(status))
        }
    }

    @discardableResult
    func register(id: UInt32, keyCode: UInt32, modifierFlags: CGEventFlags) -> Bool {
        unregister(id: id)
        installHandler()

        var carbonMods: UInt32 = 0
        if modifierFlags.contains(.maskAlternate) { carbonMods |= UInt32(optionKey) }
        if modifierFlags.contains(.maskControl) { carbonMods |= UInt32(controlKey) }
        if modifierFlags.contains(.maskCommand) { carbonMods |= UInt32(cmdKey) }
        if modifierFlags.contains(.maskShift) { carbonMods |= UInt32(shiftKey) }

        var hotKeyRef: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4d55524d), id: id) // 'MURM'
        let status = RegisterEventHotKey(
            keyCode,
            carbonMods,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr, let ref = hotKeyRef {
            registeredHotKeys[id] = ref
            Log.hotkey.info("Carbon hotkey registered for ID \(id), keyCode \(keyCode), mods \(carbonMods)")
            return true
        } else {
            Log.hotkey.error("RegisterEventHotKey failed: \(status)")
            Diagnostics.error("hotkey.carbon.register", code: Int(status))
            return false
        }
    }

    func unregister(id: UInt32) {
        if let ref = registeredHotKeys.removeValue(forKey: id) {
            UnregisterEventHotKey(ref)
        }
    }

    func unregisterAll() {
        for (_, ref) in registeredHotKeys {
            UnregisterEventHotKey(ref)
        }
        registeredHotKeys.removeAll()
    }

    private func handleEvent(id: UInt32, isPressed: Bool) {
        if isPressed {
            onHotKeyPress?(id)
        } else {
            onHotKeyRelease?(id)
        }
    }
}
