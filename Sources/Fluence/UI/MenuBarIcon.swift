import AppKit
import FluenceCore
import SwiftUI

/// The menu bar icon: a waveform, the dictation's filled waveform or a meeting's record mark,
/// and (FLU-80) a blue dot while a downloaded update waits to be installed.
struct MenuBarIcon: View {
    let controller: DictationController
    private let updater = AppUpdater.shared

    var body: some View {
        // MARK: Notetaker (capture) — the icon shows a meeting is being recorded.
        let symbol = MeetingController.shared.isRecording
            ? "record.circle"
            : (controller.state.isActive ? "waveform.circle.fill" : "waveform")
        if UpdateMenuItem.showsDot(updaterRunning: updater.isRunning, readyVersion: updater.readyVersion) {
            Image(nsImage: Self.withDot(symbol))
        } else {
            Image(systemName: symbol)
        }
    }

    private static var dotted: [String: NSImage] = [:]

    /// A menu bar icon is a template image, which macOS paints in one colour: the dot needs
    /// an ordinary image. Drawn on demand, so the symbol follows the menu bar's light or dark
    /// appearance like a template would, and the dot takes the accent of that appearance.
    private static func withDot(_ symbol: String) -> NSImage {
        if let image = dotted[symbol] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: DS.MenuBar.symbolSize, weight: .regular)
        guard let base = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return NSImage() }
        let accent = NSColor(DS.Color.accent)
        let image = NSImage(size: base.size, flipped: false) { rect in
            base.draw(in: rect)
            NSColor.headerTextColor.set()
            rect.fill(using: .sourceAtop)
            let side = DS.MenuBar.dotSize
            let dot = NSRect(x: rect.maxX - side, y: rect.maxY - side, width: side, height: side)
            // A clear ring around the dot keeps it apart from the symbol's strokes.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dot.insetBy(dx: -DS.MenuBar.dotRing, dy: -DS.MenuBar.dotRing)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            accent.setFill()
            NSBezierPath(ovalIn: dot).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Fluence, mise à jour prête"
        dotted[symbol] = image
        return image
    }
}
