import AppKit
import ApplicationServices
import Carbon.HIToolbox
import FluenceCore
import Foundation

/// Types text into the focused field of another app.
///
/// Tried in order:
/// 1. Writing the focused element's `kAXSelectedTextAttribute`: instant, and the pasteboard
///    is never touched.
/// 2. Pasting with a synthetic ⌘V, the route that reaches Electron and any app with a flaky
///    AX implementation. The pasteboard is only lent (`PasteboardLoan`, FLU-120): the item is
///    transient, concealed and kept off Universal Clipboard, and the user's contents come back
///    type for type as soon as the paste is seen. A dictation never changes the clipboard.
///
/// The first route counts only once the caret is seen to move. A `.success` from the write
/// means little: Chrome, Electron apps (VS Code, Cursor, Slack, Discord) and most terminals
/// claim the attribute is settable, take the value and throw it away.
///
/// The focused element is still the user's own field because the HUD is a non-activating
/// panel and never takes focus.
@MainActor
enum TextInjector {
    /// How long any one AX call may wait on the target app. The default is 6 s, on the main
    /// thread: a hung app would freeze Fluence — HUD, menu, hotkey — along with it. Half a
    /// second is ample for a responsive app; a frozen one falls through to the paste path.
    private static let axTimeout: Float = 0.5

    /// Where the text went, so the HUD and the sound tell the truth (FLU-27, FLU-29).
    enum Outcome: Equatable {
        /// Typed into the focused field, or pasted there — known only once the paste was
        /// actually sent, never before (FLU-29: the success sound used to play ~40 ms early).
        case inserted
        /// Not typed, and not put on the clipboard either (FLU-120): without the Accessibility
        /// grant no paste can land, or the app in front is not the one the text was meant for.
        /// The text stays the last dictation, for ⌃⌘V and the history.
        case notTyped(CapsuleMessage.NotTypedReason)
        /// Something else wrote to the clipboard just before the paste: nothing was pasted,
        /// and the clipboard holds that other content, not the dictation.
        case pasteSkipped
    }

    /// Types `text` into the focused field and returns once that is done — after the paste
    /// itself on the ⌘V route, so the caller's success sound never comes before the text.
    @discardableResult
    static func insert(_ text: String) async -> Outcome {
        guard !text.isEmpty else { return .inserted }
        // FLU-37: Fluence's own field (the onboarding's « Essayer »), typed in-process. An
        // Accessibility call from Fluence to itself would wait on its own main thread, which is
        // the thread making it.
        if let field = ownFocusedField {
            field.insertText(text, replacementRange: field.selectedRange())
            Log.inject.info("typed into Fluence's own field (\(text.count) chars)")
            return .inserted
        }
        // On the system-wide element this sets the timeout for every AX call the app makes.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axTimeout)

        switch insertViaAccessibility(text) {
        case .verified:
            Log.inject.info("inserted through Accessibility (\(text.count) chars)")
            return .inserted
        case .unverified(let reason):
            guard AXIsProcessTrusted() else {
                // A posted ⌘V would be dropped, and the clipboard is the user's (FLU-120).
                Log.inject.error("no Accessibility grant — transcript not typed")
                Diagnostics.error("inject.noAccessibility")
                return .notTyped(.noAccessibility)
            }
            Log.inject.info("AX insert not verified (\(reason, privacy: .public)) — pasting instead")
            return await insertViaPasteboard(text)
        }
    }

    /// Whether the next `insert` lands in a field of Fluence's own windows.
    static var typesIntoOwnField: Bool { ownFocusedField != nil }

    /// The editable text view that has the focus in Fluence's key window, while Fluence is the
    /// active app. The HUD is a non-activating panel and never key, so this is never it.
    private static var ownFocusedField: NSTextView? {
        guard NSApp.isActive,
              let view = NSApp.keyWindow?.firstResponder as? NSTextView,
              view.isEditable
        else { return nil }
        return view
    }

    /// FLU-93: a few characters on each side of the caret (or the selection) in the focused
    /// field, for `InsertionContext`: read once, never kept or logged. Nil in a password field
    /// and where the app exposes no text (most Electron apps, many terminals).
    static func caretContext(reach: Int = 4) -> (before: String, after: String)? {
        guard !typesIntoOwnField else { return nil }
        // Shorter than the insert's budget: this only refines the text, it must not delay it.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.1)
        defer { AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axTimeout) }
        guard let element = AXRead.focusedElement(), !isSecure(element),
              let selection = AXRead.range(element, kAXSelectedTextRangeAttribute),
              let count = AXRead.copy(element, kAXNumberOfCharactersAttribute) as? Int,
              selection.location >= 0, selection.location + selection.length <= count
        else { return nil }
        let start = max(0, selection.location - reach)
        let end = selection.location + selection.length
        guard let before = string(of: element, in: CFRange(location: start, length: selection.location - start)),
              let after = string(of: element, in: CFRange(location: end, length: min(count, end + reach) - end))
        else { return nil }
        return (before, after)
    }

    /// FLU-93: a password field has the focus; nothing is read from it or fitted to it.
    static var focusIsSecure: Bool {
        AXRead.focusedElement().map(isSecure) ?? false
    }

    private static func isSecure(_ element: AXUIElement) -> Bool {
        AXRead.string(element, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String)
            || AXRead.string(element, kAXRoleAttribute) == "AXSecureTextField"
    }

    private static func string(of element: AXUIElement, in range: CFRange) -> String? {
        guard range.length > 0 else { return "" }
        var range = range
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var result: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            value,
            &result
        ) == .success else { return nil }
        return result as? String
    }

    private enum AccessibilityResult {
        case verified
        case unverified(String)
    }

    // MARK: - Accessibility

    private static func insertViaAccessibility(_ text: String) -> AccessibilityResult {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success, let focusedValue else {
            return .unverified("no focused element")
        }

        // `as?` to a CF type can never fail, so it would test nothing.
        let element = unsafeDowncast(focusedValue as AnyObject, to: AXUIElement.self)

        var settable: DarwinBoolean = false
        guard AXUIElementIsAttributeSettable(element, kAXSelectedTextAttribute as CFString, &settable) == .success,
              settable.boolValue
        else {
            return .unverified("selected text not settable")
        }

        // No caret to compare means no way to check the write: paste instead of guessing.
        guard let before = selectedRange(of: element) else {
            return .unverified("no readable selection range")
        }

        guard AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFString
        ) == .success else {
            return .unverified("write failed")
        }

        guard let after = selectedRange(of: element) else {
            return .unverified("selection range unreadable after the write")
        }

        // Any movement counts. Wrongly calling this a failure pastes the text twice, which is
        // worse than losing it, and newline rewriting or autocorrect can move the caret by more
        // or less than the text's UTF-16 length. Only a caret that stayed put proves a loss.
        guard after.location != before.location || after.length != before.length else {
            return .unverified("selection did not move (location \(before.location))")
        }

        return .verified
    }

    private static func selectedRange(of element: AXUIElement) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw
        else { return nil }
        let value = unsafeDowncast(raw as AnyObject, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    // MARK: - Paste

    /// The loan still out, if any. A dictation pasted before the previous one is given back
    /// takes over its snapshot — the user's contents — and its restore.
    private static var loan: PasteboardLoan?

    /// Upper bound on how long the pasteboard holds the dictation before the user's previous
    /// contents come back. Usually far less: the wait ends as soon as the paste is seen to land.
    private static let pasteWindow: Duration = .seconds(1)
    private static let pastePoll: Duration = .milliseconds(50)

    /// Pastes with ⌘V and returns once the paste was sent and, where the caret can be read,
    /// seen to land; restoring the user's clipboard carries on afterwards.
    private static func insertViaPasteboard(_ text: String) async -> Outcome {
        let pasteboard = NSPasteboard.general
        let lent = PasteboardLoan(lending: text, on: pasteboard, source: Bundle.main.bundleIdentifier, after: loan)
        loan = lent
        if lent.snapshot.unreadableTypes > 0 {
            // A promise its owner did not keep: that type cannot come back. A count, no content.
            Log.inject.error("clipboard: \(lent.snapshot.unreadableTypes, privacy: .public) type(s) could not be saved")
            Diagnostics.error("inject.clipboardTypeUnreadable", code: lent.snapshot.unreadableTypes)
        }
        let caretBefore = focusedSelection()

        // A ⌘V sent at once can reach the app before it notices our write, and paste the old
        // contents instead.
        try? await Task.sleep(for: .milliseconds(40))

        // Something else wrote to the pasteboard in those 40 ms. Pasting now would paste
        // *its* contents — possibly a password — into the user's document.
        guard lent.isOut(on: pasteboard) else {
            // The newer content wins and stays; there is nothing of ours left to give back.
            if loan?.generation == lent.generation { loan = nil }
            Log.inject.error("pasteboard changed before ⌘V — paste skipped")
            Diagnostics.error("inject.pasteboardChanged")
            return .pasteSkipped
        }
        guard postCommandV() else {
            giveBack(lent, to: pasteboard)
            Log.inject.error("no Accessibility grant — transcript not typed")
            Diagnostics.error("inject.noAccessibility")
            return .notTyped(.noAccessibility)
        }
        Log.inject.info("pasted (\(text.count) chars)")

        // The caller's « done » waits for the caret to move, or for `landedWindow` where it
        // cannot be read (most Electron apps): the ⌘V has reached the app by then.
        let landed = await waitForPaste(of: lent, on: pasteboard, caretBefore: caretBefore, upTo: landedWindow)
        if landed {
            giveBack(lent, to: pasteboard)
        } else {
            Log.inject.info("paste sent; the caret could not confirm it yet")
            Task { @MainActor in
                // The rest of the window before the clipboard comes back: the app may read it late.
                await waitForPaste(of: lent, on: pasteboard, caretBefore: caretBefore, upTo: pasteWindow - landedWindow)
                giveBack(lent, to: pasteboard)
            }
        }
        return .inserted
    }

    /// How long the caller waits for evidence of the paste before calling it done.
    private static let landedWindow: Duration = .milliseconds(250)

    /// Waits until the paste has visibly landed, someone else takes the pasteboard, or
    /// `pasteWindow` runs out — whichever comes first.
    ///
    /// The paste is asynchronous in the target app and there is no notification for "the
    /// pasteboard was read". The caret moving is the best evidence available; when it can't be
    /// read (the Electron apps that brought us to this fallback often can't), the full window
    /// is the margin instead of a guess tuned on one machine.
    /// - Returns: whether the paste was seen: the caret moved, or someone took the pasteboard.
    @discardableResult
    private static func waitForPaste(
        of lent: PasteboardLoan,
        on pasteboard: NSPasteboard,
        caretBefore: CFRange?,
        upTo window: Duration
    ) async -> Bool {
        let deadline = ContinuousClock.now + window
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: pastePoll)
            // A rewrite of the dictation itself (a clipboard manager) is no sign of the paste.
            if !lent.isOut(on: pasteboard) { return true }
            if let caretBefore, let caret = focusedSelection(),
               caret.location != caretBefore.location || caret.length != caretBefore.length {
                // One more poll's grace: some apps read a second, richer type after the first.
                try? await Task.sleep(for: pastePoll)
                return true
            }
        }
        return false
    }

    /// Puts back what the user had (or an empty pasteboard), unless someone else wrote
    /// meanwhile — that newer content wins — or a later dictation took the loan over.
    private static func giveBack(_ lent: PasteboardLoan, to pasteboard: NSPasteboard) {
        guard loan?.generation == lent.generation else { return }
        loan = nil
        if !lent.giveBack(to: pasteboard) {
            Log.inject.info("pasteboard changed since the paste — left as is")
        }
    }

    /// The focused element's selection, used only to notice that a paste moved the caret.
    private static func focusedSelection() -> CFRange? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateSystemWide(),
            kAXFocusedUIElementAttribute as CFString,
            &focused
        ) == .success, let focused else { return nil }
        return selectedRange(of: unsafeDowncast(focused as AnyObject, to: AXUIElement.self))
    }

    /// Posts ⌘V. Returns false when it cannot land: without the Accessibility grant a posted
    /// event is silently dropped. System Events is no way around it — GUI scripting needs the
    /// same grant, plus an Apple Events entitlement the app deliberately doesn't carry.
    @discardableResult
    private static func postCommandV() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        let vKey = keyCode(producing: "v") ?? CGKeyCode(kVK_ANSI_V)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return false }

        // Assigned, not inherited: a modifier the user is still touching must not ride along.
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    /// The physical key that types `character` with ⌘ held, on the current layout.
    ///
    /// Key codes are positions, not letters: `kVK_ANSI_V` is where V sits on QWERTY, and on
    /// Dvorak that key is K — so a hard-coded ⌘V arrives as ⌘K. Translating with ⌘ held
    /// also gets "Dvorak – QWERTY ⌘" right, where shortcuts deliberately keep QWERTY
    /// positions. Layouts that type no Latin letters (Russian, Greek…) fall back to the
    /// ASCII-capable layout macOS itself uses for shortcuts.
    /// Also used by `HotkeyMonitor` to recognise ⌃⌘V and ⌃⌘C on any layout.
    static func keyCode(producing character: Character) -> CGKeyCode? {
        let sources = [
            TISCopyCurrentKeyboardLayoutInputSource(),
            TISCopyCurrentASCIICapableKeyboardLayoutInputSource(),
        ]
        for case let source? in sources.map({ $0?.takeRetainedValue() }) {
            guard let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { continue }
            let layoutData = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
            let found = layoutData.withUnsafeBytes { bytes -> CGKeyCode? in
                guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else {
                    return nil
                }
                let commandHeld = UInt32((cmdKey >> 8) & 0xFF)
                for code in 0..<128 {
                    var deadKeyState: UInt32 = 0
                    var length = 0
                    var characters = [UniChar](repeating: 0, count: 4)
                    let status = UCKeyTranslate(
                        layout,
                        UInt16(code),
                        UInt16(kUCKeyActionDown),
                        commandHeld,
                        UInt32(LMGetKbdType()),
                        OptionBits(kUCKeyTranslateNoDeadKeysMask),
                        &deadKeyState,
                        characters.count,
                        &length,
                        &characters
                    )
                    guard status == noErr, length == 1 else { continue }
                    if Character(String(utf16CodeUnits: characters, count: 1).lowercased()) == character {
                        return CGKeyCode(code)
                    }
                }
                return nil
            }
            if let found { return found }
        }
        return nil
    }
}
