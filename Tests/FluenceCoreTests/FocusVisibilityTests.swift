import Testing

@testable import FluenceCore

/// The keyboard focus ring shows only for keyboard navigation (FLU-38), never because a window
/// opened (FLU-18).
struct FocusVisibilityTests {
    @Test("a window that just opened shows no ring on its first control")
    func noRingOnOpen() {
        let state = FocusVisibility()
        #expect(!state.showsRing(keyWindow: 7))
    }

    @Test("Tab in a window shows the ring there")
    func tabShowsRing() {
        var state = FocusVisibility()
        state.handle(.focusKey(window: 7))
        #expect(state.showsRing(keyWindow: 7))
    }

    @Test("a click hides the ring")
    func clickHides() {
        var state = FocusVisibility()
        state.handle(.focusKey(window: 7))
        state.handle(.pointerDown)
        #expect(!state.showsRing(keyWindow: 7))
    }

    @Test("a window opened after tabbing elsewhere shows no ring until Tab is pressed in it")
    func newWindowAfterTabbing() {
        var state = FocusVisibility()
        state.handle(.focusKey(window: 7))
        #expect(!state.showsRing(keyWindow: 8))
        state.handle(.focusKey(window: 8))
        #expect(state.showsRing(keyWindow: 8))
        #expect(!state.showsRing(keyWindow: 7))
    }

    @Test("no key window, no ring")
    func noKeyWindow() {
        var state = FocusVisibility()
        state.handle(.focusKey(window: 7))
        #expect(!state.showsRing(keyWindow: nil))
    }

    @Test("Tab and ⇧Tab move the focus; ⌘Tab, ⌃Tab and other keys do not")
    func focusKeys() {
        #expect(FocusVisibility.movesFocus(keyCode: 48, command: false, control: false))
        #expect(!FocusVisibility.movesFocus(keyCode: 48, command: true, control: false))
        #expect(!FocusVisibility.movesFocus(keyCode: 48, command: false, control: true))
        #expect(!FocusVisibility.movesFocus(keyCode: 49, command: false, control: false))  // Space
        #expect(!FocusVisibility.movesFocus(keyCode: 36, command: false, control: false))  // Return
    }
}
