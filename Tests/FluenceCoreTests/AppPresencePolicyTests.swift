import Testing

@testable import FluenceCore

/// Dock icon or menu bar only (FLU-59).
struct AppPresencePolicyTests {
    typealias Facts = AppPresencePolicy.WindowFacts

    static let visibleWindow = Facts(isVisible: true, isMiniaturized: false, isPanel: false, isTitled: true)
    static let closedWindow = Facts(isVisible: false, isMiniaturized: false, isPanel: false, isTitled: true)
    static let minimisedWindow = Facts(isVisible: false, isMiniaturized: true, isPanel: false, isTitled: true)
    static let hud = Facts(isVisible: true, isMiniaturized: false, isPanel: true, isTitled: false)
    static let statusItem = Facts(isVisible: true, isMiniaturized: false, isPanel: false, isTitled: false)

    @Test("a visible window keeps the app in the Dock")
    func visibleWindowStays() {
        #expect(!AppPresencePolicy.shouldRunInBackground(windows: [Self.visibleWindow]))
    }

    @Test("with every window closed, the app goes to the menu bar")
    func allClosed() {
        #expect(AppPresencePolicy.shouldRunInBackground(windows: [Self.closedWindow, Self.closedWindow]))
        #expect(AppPresencePolicy.shouldRunInBackground(windows: []))
    }

    @Test("a minimised window still counts as open")
    func minimisedCounts() {
        #expect(!AppPresencePolicy.shouldRunInBackground(windows: [Self.minimisedWindow]))
    }

    @Test("the HUD, panels and the status item never keep the Dock icon")
    func panelsDoNotCount() {
        #expect(AppPresencePolicy.shouldRunInBackground(windows: [Self.hud, Self.statusItem, Self.closedWindow]))
    }

    @Test("a closing window is judged by its kind, not by whether it still shows")
    func closingWindowKind() {
        #expect(AppPresencePolicy.isUserWindow(Self.closedWindow))
        #expect(!AppPresencePolicy.isUserWindow(Self.hud))
        #expect(!AppPresencePolicy.isUserWindow(Self.statusItem))
    }

    @Test("one open window among closed ones is enough")
    func oneOpenAmongClosed() {
        #expect(!AppPresencePolicy.shouldRunInBackground(windows: [Self.closedWindow, Self.hud, Self.visibleWindow]))
    }
}
