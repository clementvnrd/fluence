import FluenceCore
import Foundation

/// Enrolled voice prints — biometric data (GDPR art. 9), so opt-in only
/// (`NotetakerSettings.voicePrintsEnabled`, off by default, decision FLU-9 #3).
///
/// - Stored sealed with the Vault master key under `Application Support/Fluence/
///   VoicePrints/` (owner-only, no backup, no Spotlight); never exported, never logged.
/// - A print is a 256-d WeSpeaker embedding from the offline diarizer, averaged over every
///   meeting the user confirmed it in.
/// - `enroll(meetingID:speakerID:name:)` enrols a voice from its meeting's *candidates*
///   (the per-voice embeddings of that meeting). Candidates are **not collected** (FLU-27):
///   no screen enrols a voice yet, and biometric data nothing uses is not kept. Enrolling
///   on rename (`docs/ROADMAP.md`, v0.3, after the FLU-33 bench) brings them back, deleted
///   with their meeting. Those sealed by earlier versions are deleted at launch
///   (`removeCandidates()`).
/// - Turning the setting off deletes everything (`deleteAll()`); the controller does it.
@MainActor
final class VoicePrintStore {
    static let shared = VoicePrintStore()

    struct VoicePrint: Codable, Sendable, Identifiable {
        var id = UUID()
        var name: String
        var embedding: [Float]
        /// How many meetings were averaged into the embedding.
        var samples: Int
        var updatedAt: Date
    }

    let root: URL
    private var printsURL: URL { root.appendingPathComponent("prints.enc") }
    private var candidatesDirectory: URL { root.appendingPathComponent("candidates", isDirectory: true) }

    /// The folder is created by the first print saved, not by opening the store.
    init(root: URL = AppPaths.support.appendingPathComponent("VoicePrints", isDirectory: true)) {
        self.root = root
    }

    // MARK: - Prints

    /// For matching only: an unreadable file reads as no prints here, which is harmless
    /// because nothing is written from it. Changes go through `change(_:)`.
    func prints() -> [VoicePrint] {
        guard NotetakerSettings.shared.voicePrintsEnabled else { return [] }
        do {
            return try SealedJSONFile.read([VoicePrint].self, at: printsURL) { try Vault.open($0) } ?? []
        } catch {
            Log.app.error("voice prints unreadable (\(String(describing: type(of: error)), privacy: .public))")
            Diagnostics.error("voicePrints.read", error)
            return []
        }
    }

    /// Reads, changes and rewrites the prints. A file that exists but cannot be opened (the
    /// Keychain refused, the key is lost) throws before anything is written: reading it as
    /// « no prints » and saving used to erase every enrolled voice (R9).
    private func change(_ edit: (inout [VoicePrint]) -> Void) throws {
        AppPaths.protect(root)
        try SealedJSONFile.update(
            [VoicePrint].self,
            at: printsURL,
            empty: [],
            open: { try Vault.open($0) },
            seal: { try Vault.seal($0) },
            change: edit
        )
    }

    /// Cosine similarity of each voice to each enrolled print whose name is allowed
    /// (calendar attendees). Feeds `SpeakerNaming`.
    func similarities(for voices: [String: [Float]], allowedNames: [String]) -> [String: [String: Double]] {
        let allowed = Set(allowedNames.map(Self.key))
        let candidates = prints().filter { allowed.contains(Self.key($0.name)) }
        guard !candidates.isEmpty else { return [:] }
        var result: [String: [String: Double]] = [:]
        for (speaker, embedding) in voices {
            for print in candidates {
                result[speaker, default: [:]][print.name] = SpeakerNaming.cosine(embedding, print.embedding)
            }
        }
        return result
    }

    /// Enrols (or reinforces) `name` with the voice of `speakerID` in a meeting.
    func enroll(meetingID: UUID, speakerID: String, name: String) throws {
        guard NotetakerSettings.shared.voicePrintsEnabled,
              let embedding = candidates(for: meetingID)[speakerID], !embedding.isEmpty
        else { return }
        try change { all in
            if let index = all.firstIndex(where: { Self.key($0.name) == Self.key(name) }) {
                var print = all[index]
                let n = Float(print.samples)
                print.embedding = Self.normalized(zip(print.embedding, embedding).map { ($0 * n + $1) / (n + 1) })
                print.samples += 1
                print.updatedAt = Date()
                all[index] = print
            } else {
                all.append(VoicePrint(name: name, embedding: Self.normalized(embedding), samples: 1, updatedAt: Date()))
            }
        }
    }

    func delete(name: String) {
        guard FileManager.default.fileExists(atPath: printsURL.path) else { return }
        do {
            try change { all in all.removeAll { Self.key($0.name) == Self.key(name) } }
        } catch {
            Log.app.error("voice print not deleted, the file was left as it is (\(String(describing: type(of: error)), privacy: .public))")
            Diagnostics.error("voicePrints.delete", error)
        }
    }

    /// The whole folder: every print, every candidate. Called when the setting is turned off
    /// and by « Tout effacer ».
    func deleteAll() {
        try? FileManager.default.removeItem(at: root)
        Log.app.info("voice prints deleted")
    }

    // MARK: - Per-meeting candidates

    func candidates(for meetingID: UUID) -> [String: [Float]] {
        let url = candidatesDirectory.appendingPathComponent(meetingID.uuidString + ".enc")
        guard let data = try? Vault.read(url) else { return [:] }
        return (try? JSONDecoder().decode([String: [Float]].self, from: data)) ?? [:]
    }

    /// Deletes the candidates earlier versions sealed after every meeting (FLU-27).
    func removeCandidates() {
        guard FileManager.default.fileExists(atPath: candidatesDirectory.path) else { return }
        try? FileManager.default.removeItem(at: candidatesDirectory)
        Log.app.info("unused voice candidates deleted")
    }

    // MARK: - Helpers

    private static func key(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(0) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }
}
