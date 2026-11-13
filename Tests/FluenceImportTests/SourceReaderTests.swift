import CryptoKit
import FluenceCore
import FluenceDictionary
import Foundation
import SQLite3
import Testing
@testable import FluenceImport

/// FLU-144: the readers, on synthetic copies of each app's format built here in a temporary
/// folder (never anyone's real files).
@Suite struct SourceReaderTests {
    let home: URL

    init() throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("flu144-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    func write(_ text: String, to path: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func sqlite(_ path: String, _ sql: String) throws {
        let url = home.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var db: OpaquePointer?
        #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(db, sql, nil, nil, &error)
        #expect(status == SQLITE_OK, "\(error.map { String(cString: $0) } ?? "")")
    }

    static let wisprSchema = """
        CREATE TABLE Dictionary (id TEXT, phrase TEXT, replacement TEXT, isSnippet INTEGER, isDeleted INTEGER, createdAt DATETIME);
        CREATE TABLE History (transcriptEntityId TEXT, asrText TEXT, formattedText TEXT, editedText TEXT, pastedText TEXT,
            timestamp DATETIME, duration FLOAT, status TEXT, audio BLOB);
        CREATE TABLE Meetings (id TEXT, title TEXT, createdAt DATETIME, endedAt INTEGER, isDeleted INTEGER, notes TEXT,
            summary TEXT, speakerMap TEXT, transcriptDeletedAt DATETIME);
        CREATE TABLE Notes (id TEXT, title TEXT, content TEXT, createdAt DATETIME, isDeleted INTEGER);
        INSERT INTO Dictionary VALUES ('d1', 'Ollivault', NULL, 0, 0, NULL), ('d2', 'nova tec', 'Novatek', 0, 0, NULL),
            ('d3', 'mon adresse', '1 rue de la Paix', 1, 0, '2026-01-02 03:04:05.000 +00:00'), ('d4', 'effacé', NULL, 0, 1, NULL),
            ('d5', '  ', NULL, 0, 0, NULL);
        INSERT INTO History VALUES
            ('h1', 'brut', 'propre', 'corrigé', 'collé', '2026-10-12 14:03:22.123 +00:00', 4.5, 'formatted', x'00'),
            ('h2', 'brut', 'propre', NULL, '', '2026-10-12 14:05:00.000 +00:00', 2, 'formatted', NULL),
            ('h3', 'brut', NULL, NULL, NULL, '2026-10-12 14:06:00.000 +00:00', 1, '', NULL),
            ('h4', 'brut', 'propre', NULL, NULL, '2026-10-12 14:07:00.000 +00:00', 1, 'dismissed', NULL),
            ('h5', '', ' ', NULL, NULL, '2026-10-12 14:08:00.000 +00:00', 1, 'formatted', NULL),
            ('h6', 'brut', NULL, NULL, NULL, '2026-10-12 14:09:00.000 +00:00', 0, 'no_audio', NULL);
        INSERT INTO Meetings VALUES
            ('m1', 'Point hebdo', '2026-10-12 09:00:00.000 +00:00', 1791882000000, 0, NULL, 'Résumé.',
             '{"assignments":{"1":{"user":null,"llm":"p1"},"2":{"user":null}},"people":{"p1":{"name":"Alice Martin"}}}', NULL),
            ('m2', 'Effacée', '2026-10-12 10:00:00.000 +00:00', NULL, 1, NULL, NULL, NULL, NULL),
            ('m3', 'Vide', '2026-10-12 11:00:00.000 +00:00', NULL, 0, NULL, NULL, NULL, NULL);
        INSERT INTO Notes VALUES ('n1', 'Idées', '- une idée', '2026-10-01 08:00:00.000 +00:00', 0),
            ('n2', 'Jetée', 'texte', '2026-10-01 08:00:00.000 +00:00', 1);
        """

    @Test func wisprFlowIsReadAsTheUserLeftIt() throws {
        try sqlite("wispr/flow.sqlite", Self.wisprSchema)
        try write("""
            {"meta":{"v":1}}
            {"id":"a","speaker":{"id":1,"name":null,"source":"refined"},"text":"Bonjour.","timestamp":"00:01"}
            {"id":"b","speaker":{"id":2,"name":null,"source":"refined"},"text":"Salut.","timestamp":"61:05"}
            {"id":"c","speaker":{"id":1,"name":null,"source":"refined"},"text":"  ","timestamp":"61:09"}
            """, to: "wispr/meetings/m1/refined.ndjson")
        let data = try WisprFlowSource.read(database: home.appendingPathComponent("wispr/flow.sqlite"),
                                           meetingsFolder: home.appendingPathComponent("wispr/meetings"))

        #expect(data.entries.map(\.fileLine) == ["Ollivault", "nova tec -> Novatek"])
        #expect(data.snippets.map(\.trigger) == ["mon adresse"])
        #expect(data.snippets.first?.id == StableID.uuid("wisprflow:snippet:d3"))

        // editedText > pastedText > formattedText > asrText; empty and failed rows skipped.
        #expect(data.dictations.map(\.text) == ["corrigé", "propre", "brut"])
        #expect(data.dictations.first?.id == StableID.uuid("wisprflow:dictation:h1"))
        #expect(abs((data.dictations.first?.date.timeIntervalSince1970 ?? 0) - 1_791_813_802.123) < 0.001)
        #expect(data.dictations.first?.seconds == 4.5)

        let meeting = try #require(data.meetings.first)
        #expect(data.meetings.count == 2)  // m1 and the note; m2 deleted, m3 empty
        #expect(meeting.title == "Point hebdo" && meeting.summary == "Résumé.")
        #expect(meeting.endedAt == Date(timeIntervalSince1970: 1_791_882_000))
        #expect(meeting.transcript.turns.map(\.speaker) == ["Alice Martin", Placeholder.voice("2")])
        #expect(meeting.transcript.turns.map(\.start) == [1, 3_665])
        #expect(data.meetings.last?.isNote == true)
        #expect(data.meetings.last?.userNotes == "- une idée")
    }

    /// Opening it changes nothing: not the bytes, not the date.
    @Test func wisprFlowsFileIsLeftUntouched() throws {
        try sqlite("wispr/flow.sqlite", Self.wisprSchema)
        let url = home.appendingPathComponent("wispr/flow.sqlite")
        func fingerprint() throws -> (String, Date?) {
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            return (digest, try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        }
        let before = try fingerprint()
        _ = try WisprFlowSource.read(database: url, meetingsFolder: home)
        let after = try fingerprint()
        #expect(before.0 == after.0 && before.1 == after.1)
        #expect(!FileManager.default.fileExists(atPath: url.path + "-journal"))
    }

    @Test func aMissingTableOrColumnReadsAsNothing() throws {
        try sqlite("wispr/flow.sqlite", "CREATE TABLE History (transcriptEntityId TEXT, asrText TEXT, timestamp DATETIME);"
            + "INSERT INTO History VALUES ('h1', 'brut', '2026-10-12 14:03:22.123 +00:00');")
        let data = try WisprFlowSource.read(database: home.appendingPathComponent("wispr/flow.sqlite"), meetingsFolder: home)
        #expect(data.dictations.map(\.text) == ["brut"])
        #expect(data.entries.isEmpty && data.meetings.isEmpty)
    }

    @Test func superwhisperRecordingsAndSettings() throws {
        try write(#"{"vocabulary":["Ollivault"," "],"replacements":[{"id":"r","original":"nova tec","with":"Novatek"}],"other":1}"#,
                  to: "superwhisper/settings/settings.json")
        try write(#"{"datetime":"2026-10-12T14:03:22","duration":4500,"result":"","llmResult":"propre","rawResult":"brut"}"#,
                  to: "superwhisper/recordings/r1/meta.json")
        try write(#"{"datetime":"2026-10-12T15:00:00","duration":60000,"kind":"meeting","result":"Tout.","segments":[{"start":0.5,"end":2,"text":"Bonjour."}]}"#,
                  to: "superwhisper/recordings/r2/meta.json")
        try write(#"{"datetime":"pas une date","result":"x"}"#, to: "superwhisper/recordings/r3/meta.json")
        let locations = ImportLocations(home: home)
        let data = SuperwhisperSource.read(settings: locations.superwhisperSettings,
                                          recordingsFolders: locations.superwhisperRecordings(includeDocuments: true))
        #expect(data.entries.map(\.fileLine) == ["Ollivault", "nova tec -> Novatek"])
        #expect(data.dictations.map(\.text) == ["propre"])
        // Stamped in UTC.
        #expect(data.dictations.first?.date == Date(timeIntervalSince1970: 1_791_813_802))
        #expect(data.dictations.first?.seconds == 4.5)
        #expect(data.meetings.first?.transcript.turns.map(\.text) == ["Bonjour."])
        #expect(data.meetings.first?.endedAt == Date(timeIntervalSince1970: 1_791_817_200 + 60))
    }

    @Test func granolaCacheHoldsItsStateAsAString() throws {
        let state: [String: Any] = ["state": [
            "documents": [
                "g1": ["id": "g1", "title": "Point hebdo", "created_at": "2026-10-12T09:00:00.000Z", "notes_markdown": "## Notes", "deleted_at": NSNull()],
                "g2": ["id": "g2", "title": "Supprimée", "created_at": "2026-10-12T09:00:00.000Z", "notes_plain": "x", "deleted_at": "2026-10-13T00:00:00Z"],
                "g3": ["id": "g3", "title": "Vide", "created_at": "2026-10-12T09:00:00.000Z"],
            ],
            "transcripts": ["g1": [
                ["text": "Bonjour.", "source": "microphone", "start_timestamp": "2026-10-12T09:01:00.000Z", "end_timestamp": "2026-10-12T09:01:02.000Z"],
                ["text": "Salut.", "source": "system", "start_timestamp": "2026-10-12T09:01:05.500Z"],
            ]],
        ]]
        let inner = String(decoding: try JSONSerialization.data(withJSONObject: state), as: UTF8.self)
        let file = try JSONSerialization.data(withJSONObject: ["cache": inner])
        let data = try GranolaSource.read(file)
        #expect(data.meetings.count == 1)
        let meeting = try #require(data.meetings.first)
        #expect(meeting.id == StableID.uuid("granola:document:g1"))
        #expect(meeting.userNotes == "## Notes")
        #expect(meeting.startedAt == Date(timeIntervalSince1970: 1_791_795_660))
        #expect(meeting.transcript.turns.map(\.start) == [0, 5.5])
        #expect(meeting.transcript.turns.map(\.speaker) == [Placeholder.me, Placeholder.voice("system")])

        let planned = ImportPlanner.meeting(meeting, app: .granola, userNames: [])
        #expect(planned.segments.first?.speakerID == "me")
        #expect(planned.speakers.allSatisfy { $0.name == nil })
        #expect(throws: ImportFailure.unreadable) { try GranolaSource.read(Data("pas du json".utf8)) }
    }

    @Test func onlyTheAppsOnDiskAreFound() throws {
        try write("{}", to: "superwhisper/settings/settings.json")
        let locations = ImportLocations(home: home)
        #expect(!locations.isFound(.wisprFlow, includeDocuments: true))
        #expect(locations.isFound(.superwhisper, includeDocuments: false))
        #expect(!locations.isFound(.granola, includeDocuments: true))
        let scans = ImportScanner.scan(locations, includeDocuments: false)
        #expect(scans.map(\.isFound) == [false, true, false])
    }
}
