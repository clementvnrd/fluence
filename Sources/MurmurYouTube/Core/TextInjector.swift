import AppKit
import ApplicationServices
import Foundation

/// Puts text into whatever field currently has keyboard focus.
///
/// Strategies, in order of reliability:
/// 1. **Accessibility (AXUIElement)** — in-place replacement without touching the pasteboard.
/// 2. **Pasteboard + ⌘V with PID targeting & hardware modifier cooldown** — works in
///    Electron apps (Slack, Discord, VS Code, Cursor), Web browsers (Chrome, Arc, Safari),
///    and native chat apps.
/// 3. **System Events AppleScript Fallback** — guaranteed fallback if event posting is blocked.
@MainActor
enum TextInjector {
    static func insert(_ text: String) async {
        guard !text.isEmpty else { return }

        switch insertViaAccessibility(text) {
        case .inserted:
            Log.inject.info("inserted via AX (\(text.count) chars)")
            // Also copy to pasteboard as backup convenience for the user
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .unverified(let reason):
            Log.inject.info("AX insert not verified (\(reason, privacy: .public)) — pasting via clipboard")
            await insertViaPasteboard(text)
        }
    }

    /// Reads currently selected text from the focused element via Accessibility.
    static func getSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let focused else {
            return nil
        }

        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)
        var selectedTextRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextRef
        ) == .success, let text = selectedTextRef as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }

        return nil
    }

    private enum AXOutcome {
        case inserted
        case unverified(String)
    }

    // MARK: - Strategy 1: Accessibility, verified

    private static func insertViaAccessibility(_ text: String) -> AXOutcome {
        let systemWide = AXUIElementCreateSystemWide()

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let focused else {
            return .unverified("no focused element")
        }

        let element = unsafeDowncast(focused as AnyObject, to: AXUIElement.self)

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue else {
            return .unverified("selected text not settable")
        }

        guard let before = selectedRange(of: element) else {
            return .unverified("no readable selection range")
        }

        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success else {
            return .unverified("set attribute failed")
        }

        guard let after = selectedRange(of: element) else {
            return .unverified("selection range unreadable after write")
        }

        let unchanged = after.location == before.location && after.length == before.length
        guard !unchanged else {
            return .unverified("selection unmoved at \(before.location)")
        }

        return .inserted
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success, let value else { return nil }

        let axValue = unsafeDowncast(value as AnyObject, to: AXValue.self)
        guard AXValueGetType(axValue) == .cfRange else { return nil }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Strategy 2: Pasteboard + Targeted ⌘V

    static func insertViaPasteboard(_ text: String) async {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // Wait 100ms for physical keyboard modifiers (Option, Control, Space) to settle
        // and for pasteboard data to propagate across macOS IPC.
        try? await Task.sleep(for: .milliseconds(100))

        if AXIsProcessTrusted() {
            Log.inject.info("Posting ⌘V via cgAnnotatedSessionEventTap (AX trusted)")
            let posted = await postCommandV()
            if !posted {
                Log.inject.notice("postCommandV failed, falling back to AppleScript")
                executeAppleScriptPaste()
            }
        } else {
            Log.inject.notice("Accessibility not trusted in TCC — posting ⌘V via System Events AppleScript")
            executeAppleScriptPaste()
        }
        Log.inject.info("pasted (\(text.count) chars) to frontmost app")
    }

    @discardableResult
    private static func postCommandV() async -> Bool {
        let vKey: CGKeyCode = 9 // kVK_ANSI_V ('v' / 'V' on ANSI and ISO AZERTY/QWERTY)

        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return false }

        // Both down and up must hold .maskCommand for proper modifier chord handling
        down.flags = .maskCommand
        up.flags = .maskCommand

        // Post to .cgAnnotatedSessionEventTap at session level so WindowServer delivers
        // directly to whichever window currently holds keyboard focus
        down.post(tap: .cgAnnotatedSessionEventTap)
        try? await Task.sleep(for: .milliseconds(35))
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }

    private static func executeAppleScriptPaste() {
        let scriptSource = "tell application \"System Events\" to keystroke \"v\" using command down"
        if let script = NSAppleScript(source: scriptSource) {
            var error: NSDictionary?
            script.executeAndReturnError(&error)
            if error == nil {
                Log.inject.info("Pasted via in-process AppleScript")
                return
            }
            Log.inject.notice("In-process AppleScript notice: \(String(describing: error))")
        }

        // Child process osascript fallback (runs directly in user GUI session)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", scriptSource]
        try? task.run()
        Log.inject.info("Triggered osascript child process paste fallback")
    }
}
