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

/// "Copier en Markdown" and "Exporter en Markdown…" for the selected meeting.
struct MeetingExportKeys: View {
    @Bindable var model: MeetingLibraryModel
    let meeting: Meeting

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            TransportKey(
                title: model.flash == Self.copied ? Self.copied : "Copier en Markdown",
                systemImage: "doc.on.doc"
            ) {
                MeetingExport.copyMarkdown(meeting)
                model.showFlash(Self.copied)
            }
            .help("Copier les notes, vos notes et la transcription en Markdown")

            TransportKey(
                title: model.flash == Self.exported ? Self.exported : "Exporter en Markdown…",
                systemImage: "square.and.arrow.up"
            ) {
                do {
                    if try MeetingExport.saveMarkdown(meeting) { model.showFlash(Self.exported) }
                } catch {
                    model.report("Le fichier Markdown n'a pas pu être écrit.")
                }
            }
            .help("Enregistrer la réunion dans un fichier Markdown")
        }
    }

    private static let copied = "Copié !"
    private static let exported = "Exporté"
}
