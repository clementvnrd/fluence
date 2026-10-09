import AppKit
import SwiftUI

/// The floating capsule that appears while the dictation key is held.
///
/// Clement's capsule sits on a generous transparent canvas (`DS.HUD.size`) so its soft
/// shadow is never clipped; clicks on the transparent part fall through to what's below.
///
/// The text field being dictated into must keep the focus, or `TextInjector` has nowhere to
/// type: so the panel is non-activating and refuses to become key or main.
@MainActor
final class HUDPanel: NSPanel {
    init(controller: DictationController, preview: HUDPreview? = nil) {
        self.controller = controller
        super.init(
            contentRect: NSRect(origin: .zero, size: DS.HUD.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        // The capsule carries a language pill and a finish button, so it takes clicks — and
        // still never focus: `canBecomeKey` is false, so the user's text field keeps it.
        ignoresMouseEvents = false

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false

        // The HUD shows the live transcript. Excluded from screen sharing, recording and
        // screenshots, so dictating during a call doesn't broadcast what you're writing.
        sharingType = .none

        let hosting = ClickThroughHostingView(rootView: HUDView(controller: controller, preview: preview))
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = hosting
    }

    private let controller: DictationController

    /// Bumped on every present, so a fade-out that finishes after the HUD was shown again
    /// knows it's stale.
    private var presentation = 0

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Centres the panel on the active screen, just above the Dock.
    ///
    /// `NSScreen.main` follows the key window, which an accessory app showing only a
    /// non-activating panel may not have; the first screen is the fallback so the HUD lands
    /// on a display rather than at the origin.
    func reposition() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            Log.app.error("HUD: no screen available to place the panel")
            return
        }
        let visible = screen.visibleFrame
        setFrameOrigin(
            NSPoint(
                x: visible.midX - frame.width / 2,
                y: visible.minY + DS.HUD.bottomOffset
            )
        )
    }

    func present() {
        // Every active state (starting, listening, finishing) lands here; dropping to
        // transparent and fading in again each time would flicker mid-dictation.
        if isVisible && alphaValue >= 1 { return }

        presentation += 1
        reposition()
        alphaValue = 0
        orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.HUD.fade
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        let presentation = self.presentation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = DS.HUD.fade
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            // Hopped rather than asserted: see AGENTS.md on `MainActor.assumeIsolated`.
            Task { @MainActor in
                // A fast re-press presented the HUD again while this fade was running;
                // hiding it now would leave the user dictating with no HUD.
                guard let self, self.presentation == presentation else { return }
                self.orderOut(nil)
            }
        }
    }
}

// MARK: FLU-5 input

/// A window that never becomes key only ever receives "first" clicks. Without this, the
/// first click on the Stop key would be spent bringing the panel forward instead of pressing.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
