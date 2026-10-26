/// When the keyboard focus ring is drawn (FLU-38): only after the keyboard moved the focus in
/// the window that has it — the web's `:focus-visible`.
///
/// A window that opens puts the focus on its first control by itself when *Keyboard
/// navigation* is on; a ring there read as a second selection (FLU-18), so the ring waits for
/// a Tab in that window. A click hides it again: the pointer is in use.
public struct FocusVisibility: Equatable, Sendable {
    public enum Event: Equatable, Sendable {
        /// A key that moves the focus between controls, pressed in this window.
        case focusKey(window: Int)
        /// A click, anywhere.
        case pointerDown
    }

    /// The window the keyboard last moved the focus in, if the pointer has not been used since.
    public private(set) var keyboardWindow: Int?

    public init() {}

    public mutating func handle(_ event: Event) {
        switch event {
        case .focusKey(let window): keyboardWindow = window
        case .pointerDown: keyboardWindow = nil
        }
    }

    /// Whether the focused control of `keyWindow` shows its ring. A window that just opened is
    /// another window, so it shows none until a Tab is pressed in it.
    public func showsRing(keyWindow: Int?) -> Bool {
        guard let keyWindow else { return false }
        return keyWindow == keyboardWindow
    }

    /// Tab and ⇧Tab move the focus; ⌘Tab belongs to the system and ⌃Tab to tab bars.
    public static func movesFocus(keyCode: UInt16, command: Bool, control: Bool) -> Bool {
        keyCode == tabKeyCode && !command && !control
    }

    /// `kVK_Tab`.
    public static let tabKeyCode: UInt16 = 48
}
