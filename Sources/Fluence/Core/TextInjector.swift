import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

/// Puts text into whatever field currently has keyboard focus.
///
/// Two strategies, in order:
/// 1. **Accessibility** — set `kAXSelectedTextAttribute` on the focused element. Clean and
///    instant, and it leaves the pasteboard untouched.
/// 2. **Pasteboard + ⌘V** — works in Electron apps and anything else with a half-hearted
///    AX implementation. The item is marked transient and concealed and kept off Universal
///    Clipboard, and the previous contents (or an empty pasteboard) come back afterwards.
///
/// The catch that makes this non-obvious: **many apps return `.success` from the AX write
/// and then do nothing.** Electron (Cursor, VS Code, Slack, Discord), Chrome, and most
/// terminal emulators all report `kAXSelectedTextAttribute` as settable, accept the write,
/// and silently drop it. So the return value is not evidence of anything — strategy 1 is
/// only trusted when the insertion point can be *observed* to have moved.
///
/// This all works because the HUD is a non-activating panel: focus never leaves the user's
/// target app, so "the focused element" is still their text field.
@MainActor
enum TextInjector {
    /// How long any one AX call may wait on the target app. The default is 6 s, on the main
    /// thread: a hung app would freeze Fluence — HUD, menu, hotkey — along with it. Half a
    /// second is ample for a responsive app; a frozen one falls through to the paste path.
    private static let axTimeout: Float = 0.5

    static func insert(_ text: String) {
        guard !text.isEmpty else { return }
        // On the system-wide element this sets the timeout for every AX call the app makes.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), axTimeout)

        switch insertViaAccessibility(text) {
        case .inserted:
            Log.inject.info("inserted via AX (\(text.count) chars)")
        case .unverified(let reason):
            Log.inject.info("AX insert not verified (\(reason, privacy: .public)) — pasting")
            insertViaPasteboard(text)
        }
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

        // Without a readable insertion point there's no way to tell a real insert from a
        // silently-dropped one, so don't gamble — go straight to the fallback.
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

        // Deliberately a *movement* check, not an exact-length check. Falling back after a
        // write that actually landed would paste the text a second time, and a duplicated
        // paragraph is far worse than a missing one. Some apps normalize newlines or run
        // autocorrect, so the caret can legitimately advance by something other than the
        // UTF-16 count — only a completely unmoved selection proves nothing happened.
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

    // MARK: - Strategy 2: Pasteboard + ⌘V

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

    private static func insertViaPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.pasteboardItems?.compactMap { item -> [NSPasteboard.PasteboardType: Data] in
            var copy: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { copy[type] = data }
            }
            return copy
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
        let ours = pasteboard.changeCount
        let caretBefore = focusedSelection()

        Task { @MainActor in
            // Give the target app a moment to observe the new pasteboard generation before
            // ⌘V arrives, or a fast paste can grab the *previous* contents.
            try? await Task.sleep(for: .milliseconds(40))

            // Something else wrote to the pasteboard in those 40 ms. Pasting now would paste
            // *its* contents — possibly a password — into the user's document.
            guard pasteboard.changeCount == ours else {
                Log.inject.error("pasteboard changed before ⌘V — paste skipped")
                return
            }
            postCommandV()
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
        let items = saved.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
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

    private static func postCommandV() {
        guard let source = CGEventSource(stateID: .privateState) else { return }
        let vKey = keyCode(producing: "v") ?? CGKeyCode(kVK_ANSI_V)

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else { return }

        // Set explicitly rather than inheriting live hardware modifier state — the user may
        // still be resting a finger on something.
        down.flags = .maskCommand
        up.flags = .maskCommand

        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    /// The physical key that types `character` with ⌘ held, on the current layout.
    ///
    /// Key codes are positions, not letters: `kVK_ANSI_V` is where V sits on QWERTY, and on
    /// Dvorak that key is K — so a hard-coded ⌘V arrives as ⌘K. Translating with ⌘ held
    /// also gets "Dvorak – QWERTY ⌘" right, where shortcuts deliberately keep QWERTY
    /// positions. Layouts that type no Latin letters (Russian, Greek…) fall back to the
    /// ASCII-capable layout macOS itself uses for shortcuts.
    private static func keyCode(producing character: Character) -> CGKeyCode? {
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
