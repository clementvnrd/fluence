import AppKit
import SwiftUI

/// Scene identifier of the meetings library window.
enum MeetingsWindowID {
    static let library = "meetings"
}

/// "Meetings" in the Window menu, ⇧⌘M.
struct MeetingsCommands: Commands {
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Meetings") {
                openWindow(id: MeetingsWindowID.library)
                NSApp.activate(ignoringOtherApps: true)
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }
    }
}

/// The same entry in the menu-bar menu.
struct MeetingsMenuButton: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Meetings…") {
            openWindow(id: MeetingsWindowID.library)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
