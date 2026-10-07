import Foundation
import Observation
import UniformTypeIdentifiers

/// Importing past meetings from transcript files or pasted text (FLU-16).
///
/// The sheet first takes files (picker or drop) or pasted text, then shows one draft at a
/// time — title, date, which speaker is the user — and saves it as an encrypted meeting
/// whose notes are then written like a recorded one's. Several files are confirmed one after
/// the other. Nothing about the transcript's content is logged.
@MainActor
@Observable
final class MeetingImportModel {
    /// One transcript waiting for confirmation.
    struct Draft {
        var transcript: ImportedTranscript
        var title: String
        var date: Date
        var me: String?
        /// The file name, or `nil` for pasted text.
        var sourceName: String?
    }

    /// Files are read whole; a transcript of a long meeting is a few hundred kilobytes.
    static let maxFileSize = 10 * 1_024 * 1_024

    /// `.txt`, Markdown, WebVTT, SubRip.
    static let fileTypes: [UTType] = [.plainText, .utf8PlainText]
        + ["md", "markdown", "vtt", "srt"].compactMap { UTType(filenameExtension: $0) }

    var isPresented = false
    var isChoosingFiles = false
    var pastedText = ""
    var draft: Draft?
    /// Files after the current draft.
    private(set) var queue: [URL] = []
    /// The draft's position among the files picked together, for "2 sur 3".
    private(set) var position: (index: Int, count: Int)?
    private(set) var problem: String?

    // MARK: - Starting

    func begin() {
        reset()
        isPresented = true
    }

    /// From the picker or a drop on the list.
    func open(_ urls: [URL]) {
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        reset()
        queue = files
        position = files.count > 1 ? (0, files.count) : nil
        isPresented = true
        advance()
    }

    func usePastedText() {
        let transcript = TranscriptImport.parse(pastedText)
        guard !transcript.turns.isEmpty else {
            problem = "Aucun texte reconnu. Collez la transcription telle quelle, une intervention par ligne."
            return
        }
        problem = nil
        draft = Self.draft(transcript, title: nil, date: Date(), sourceName: nil)
    }

    // MARK: - Confirming

    /// Saves the draft as a meeting and moves on to the next file. Returns the meeting's ID.
    @discardableResult
    func commit(store: MeetingStore, generator: MeetingNotesGenerator) -> UUID? {
        guard let draft else { return nil }
        let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let meeting = TranscriptImport.meeting(
            from: draft.transcript,
            title: title.isEmpty ? "Réunion importée" : title,
            startedAt: draft.date,
            me: draft.me,
            sourceName: draft.sourceName
        )
        do {
            try store.save(meeting)
        } catch {
            problem = "La réunion n'a pas pu être enregistrée : \(error.localizedDescription)"
            return nil
        }
        Log.app.info("meeting imported — \(draft.transcript.format.rawValue, privacy: .public), \(meeting.segments.count) segments, \(meeting.speakers.count) speakers")
        generator.meetingFinalized(meeting.id)
        advance()
        return meeting.id
    }

    /// Leaves this file out and moves on to the next one, if any.
    func skip() {
        advance()
    }

    func cancel() {
        reset()
        isPresented = false
    }

    // MARK: - Reading

    private func advance() {
        draft = nil
        problem = nil
        while !queue.isEmpty {
            let url = queue.removeFirst()
            if let position { self.position = (position.index + 1, position.count) }
            switch Self.read(url) {
            case .success(let transcript):
                let name = url.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
                draft = Self.draft(transcript, title: name, date: Self.fileDate(url), sourceName: url.lastPathComponent)
                return
            case .failure(let message):
                // Say which file was skipped, and keep going with the others.
                problem = message
            }
        }
        // Nothing left: close, unless a skipped file needs explaining.
        if problem == nil { isPresented = false }
    }

    private enum ReadResult {
        case success(ImportedTranscript)
        case failure(String)
    }

    private static func read(_ url: URL) -> ReadResult {
        let name = url.lastPathComponent
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= maxFileSize else {
            return .failure("« \(name) » est trop gros pour une transcription (plus de 10 Mo).")
        }
        guard let data = try? Data(contentsOf: url) else {
            return .failure("« \(name) » n'a pas pu être lu.")
        }
        guard let text = decode(data) else {
            return .failure("« \(name) » n'est pas un fichier texte.")
        }
        let transcript = TranscriptImport.parse(text)
        guard !transcript.turns.isEmpty else {
            return .failure("Aucun texte reconnu dans « \(name) ».")
        }
        return .success(transcript)
    }

    /// UTF-8 (with or without a byte-order mark), UTF-16 with one, then Windows Latin-1 —
    /// what older Teams and Word exports use for French.
    private static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        guard !data.contains(0) else { return nil }  // binary
        return String(data: data, encoding: .windowsCP1252)
    }

    /// When the file was made: exports are written at the end of the meeting.
    private static func fileDate(_ url: URL) -> Date {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    private static func draft(_ transcript: ImportedTranscript, title: String?, date: Date, sourceName: String?) -> Draft {
        Draft(
            transcript: transcript,
            title: transcript.title ?? title ?? "",
            date: date,
            me: TranscriptImport.guessMe(in: transcript.speakers, userNames: [NSFullUserName()]),
            sourceName: sourceName
        )
    }

    private func reset() {
        draft = nil
        queue = []
        position = nil
        problem = nil
        pastedText = ""
        isChoosingFiles = false
    }
}
