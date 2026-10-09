import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Markdown out of the encrypted store, only when the user asks for it.
///
/// Both paths are explicit user actions, so the text leaves the vault in plaintext by
/// design. The copy is marked `.currentHostOnly` so Universal Clipboard does not carry a
/// whole meeting to the user's other devices, and transient and concealed (FLU-32) so
/// clipboard managers that honour nspasteboard.org's markers keep it out of their history,
/// as a dictation is.
@MainActor
enum MeetingExport {
    static func copyMarkdown(_ meeting: Meeting) {
        let pasteboard = NSPasteboard.general
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        item.setString(meeting.markdown(), forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        if let bundleID = Bundle.main.bundleIdentifier {
            item.setString(bundleID, forType: NSPasteboard.PasteboardType("org.nspasteboard.source"))
        }
        pasteboard.writeObjects([item])
    }

    /// Asks where to save, then writes the file. False when the user cancelled.
    static func saveMarkdown(_ meeting: Meeting) throws -> Bool {
        let panel = NSSavePanel()
        panel.title = "Exporter la réunion en Markdown"
        panel.prompt = "Exporter"
        panel.nameFieldStringValue = meeting.markdownFilename
        panel.allowedContentTypes = [UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try Data(meeting.markdown().utf8).write(to: url, options: [.atomic])
        return true
    }
}
