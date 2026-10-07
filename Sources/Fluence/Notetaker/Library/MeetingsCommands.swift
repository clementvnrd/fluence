import AppKit
import SwiftUI

/// "Réunions" in the Window menu, ⇧⌘M: the main window's meetings (FLU-12 — the library
/// is no longer a window of its own).
struct MeetingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Réunions") {
                MainNavigation.shared.show(.meetings, openWindow: openWindow)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }
    }
}

/// The same entry in the menu-bar menu.
struct MeetingsMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Réunions…") {
            MainNavigation.shared.show(.meetings, openWindow: openWindow)
        }
    }
}
