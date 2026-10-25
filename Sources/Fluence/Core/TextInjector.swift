import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Types text into the focused field of another app.
///
/// Tried in order:
/// 1. Writing the focused element's `kAXSelectedTextAttribute`: instant, and the pasteboard
///    is never touched.
/// 2. Pasting with a synthetic ⌘V, the route that reaches Electron and any app with a flaky
///    AX implementation. The item is marked transient and concealed and kept off Universal
///    Clipboard, and the previous contents (or an empty pasteboard) come back afterwards.
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

    /// Where the text went, so the HUD and the sound tell the truth (FLU-27).
    enum Outcome: Equatable {
        /// Typed into the focused field, or pasted there.
        case inserted
        /// Only put on the clipboard: without the Accessibility grant no paste can land, and
        /// the user has to press ⌘V.
        case onClipboard
    }

    @discardableResult
    static func insert(_ text: String) -> Outcome {
        guard !text.isEmpty else { return .inserted }
        // On the system-wide element this sets the timeout for every AX call the app makes.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axTimeout)

        switch insertViaAccessibility(text) {
        case .verified:
            Log.inject.info("inserted through Accessibility (\(text.count) chars)")
        case .unverified(let reason):
            guard AXIsProcessTrusted() else {
                // A posted ⌘V would be dropped: the dictation stays on the pasteboard (still
                // concealed and transient) for the user's own ⌘V.
                Log.inject.error("no Accessibility grant — transcript left on the pasteboard")
                Diagnostics.error("inject.noAccessibility")
                putOnPasteboard(text)
                return .onClipboard
            }
            Log.inject.info("AX insert not verified (\(reason, privacy: .public)) — pasting instead")
            insertViaPasteboard(text)
        }
        return .inserted
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

    /// Markers from nspasteboard.org that clipboard managers (Maccy, Paste, Raycast, Alfred,
    /// 1Password's own clipboard handling…) honour: transient and concealed items are not
    /// added to their history, so a dictation pasted this way doesn't end up in a searchable
    /// archive of everything you've said.
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    private static let sourceType = NSPasteboard.PasteboardType("org.nspasteboard.source")

    /// Upper bound on how long the pasteboard holds the dictation before the user's previous
    /// contents come back. Usually far less: the wait ends as soon as the paste is seen to land.
    private static let pasteWindow: Duration = .seconds(1)
    private static let pastePoll: Duration = .milliseconds(50)

    /// Writes the dictation to the pasteboard, marked transient and concealed, this Mac only.
    ///
    /// - Returns: what the pasteboard held before, and the generation of our write.
    @discardableResult
    private static func putOnPasteboard(_ text: String) -> (saved: [[NSPasteboard.PasteboardType: Data]], generation: Int) {
        let pasteboard = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { entry[type] = data }
            }
            return entry
        } ?? []

        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)
        item.setData(Data(), forType: concealedType)
        if let bundleID = Bundle.main.bundleIdentifier {
            item.setString(bundleID, forType: sourceType)
        }

        // `.currentHostOnly` keeps it out of Universal Clipboard, which would otherwise hand
        // the dictation to every device signed in to the same account.
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.writeObjects([item])
        return (saved, pasteboard.changeCount)
    }

    private static func insertViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let (saved, ours) = putOnPasteboard(text)
        let caretBefore = focusedSelection()

        // A ⌘V sent at once can reach the app before it notices our write, and paste the old
        // contents instead.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))

            // Something else wrote to the pasteboard in those 40 ms. Pasting now would paste
            // *its* contents — possibly a password — into the user's document.
            guard pasteboard.changeCount == ours else {
                Log.inject.error("pasteboard changed before ⌘V — paste skipped")
                Diagnostics.error("inject.pasteboardChanged")
                return
            }
            guard postCommandV() else {
                // No paste is possible, so the dictation stays on the pasteboard (still
                // concealed and transient) for the user's own ⌘V instead of being restored away.
                Log.inject.error("no Accessibility grant — transcript left on the pasteboard")
                Diagnostics.error("inject.noAccessibility")
                return
            }
            Log.inject.info("pasted (\(text.count) chars)")

            await waitForPaste(on: pasteboard, generation: ours, caretBefore: caretBefore)
            restore(saved, to: pasteboard, ifStill: ours)
        }
    }

    /// Waits until the paste has visibly landed, someone else takes the pasteboard, or
    /// `pasteWindow` runs out — whichever comes first.
    ///
    /// The paste is asynchronous in the target app and there is no notification for "the
    /// pasteboard was read". The caret moving is the best evidence available; when it can't be
    /// read (the Electron apps that brought us to this fallback often can't), the full window
    /// is the margin instead of a guess tuned on one machine.
    private static func waitForPaste(
        on pasteboard: NSPasteboard,
        generation: Int,
        caretBefore: CFRange?
    ) async {
        let deadline = ContinuousClock.now + pasteWindow
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: pastePoll)
            if pasteboard.changeCount != generation { return }
            if let caretBefore, let caret = focusedSelection(),
               caret.location != caretBefore.location || caret.length != caretBefore.length {
                // One more poll's grace: some apps read a second, richer type after the first.
                try? await Task.sleep(for: pastePoll)
                return
            }
        }
    }

    /// Puts back what the user had — or leaves the pasteboard empty if it was empty — but only
    /// while the pasteboard still holds our item. If anything else wrote to it meanwhile (the
    /// user copied something, a password manager filled), that newer content wins.
    private static func restore(
        _ saved: [[NSPasteboard.PasteboardType: Data]],
        to pasteboard: NSPasteboard,
        ifStill generation: Int
    ) {
        guard pasteboard.changeCount == generation else {
            Log.inject.info("pasteboard changed since the paste — left as is")
            return
        }
        pasteboard.clearContents()
        guard !saved.isEmpty else { return }
        // Items read from a pasteboard die with the next clear, so each one is rebuilt from
        // its saved types.
        let rebuilt = saved.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(rebuilt)
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
