import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Markdown out of the encrypted store, only when the user asks for it.
///
/// Both paths are explicit user actions, so the text leaves the vault in plaintext by
/// design. The copy is marked `.currentHostOnly` so Universal Clipboard does not carry a
/// whole meeting to the user's other devices.
@MainActor
enum MeetingExport {
    static func copyMarkdown(_ meeting: Meeting) {
        let pasteboard = NSPasteboard.general
        _ = pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(meeting.markdown(), forType: .string)
    }

    /// Asks where to save, then writes the file. False when the user cancelled.
    static func saveMarkdown(_ meeting: Meeting) throws -> Bool {
        let panel = NSSavePanel()
        panel.title = "Export Meeting as Markdown"
        panel.prompt = "Export"
        panel.nameFieldStringValue = meeting.markdownFilename
        panel.allowedContentTypes = [UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        try Data(meeting.markdown().utf8).write(to: url, options: [.atomic])
        return true
    }
}

/// "Copy as Markdown" and "Export Markdown…" for the selected meeting.
struct MeetingExportKeys: View {
    @Bindable var model: MeetingLibraryModel
    let meeting: Meeting

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            TransportKey(
                title: model.flash == Self.copied ? Self.copied : "Copy as Markdown",
                systemImage: "doc.on.doc"
            ) {
                MeetingExport.copyMarkdown(meeting)
                model.showFlash(Self.copied)
            }
            .help("Copy the notes, your notes and the transcript as Markdown")

            TransportKey(
                title: model.flash == Self.exported ? Self.exported : "Export Markdown…",
                systemImage: "square.and.arrow.up"
            ) {
                do {
                    if try MeetingExport.saveMarkdown(meeting) { model.showFlash(Self.exported) }
                } catch {
                    model.report("The Markdown file could not be written.")
                }
            }
            .help("Save the meeting as a Markdown file")
        }
    }

    private static let copied = "Copied"
    private static let exported = "Exported"
}
