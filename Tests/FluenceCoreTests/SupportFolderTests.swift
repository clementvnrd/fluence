import Foundation
import Testing

@testable import FluenceCore

/// R6: the support folder was excluded from Time Machine whole, dictionary included.
struct SupportFolderTests {
    private func makeFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SupportFolderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func exclude(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    @Test func theDictionaryComesBackIntoTimeMachine() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        for name in ["dictionary.txt", "dictionary.txt.bak", "history.sealed", "snippets.sealed", ".metadata_never_index"] {
            manager.createFile(atPath: root.appendingPathComponent(name).path, contents: Data("x".utf8))
        }
        for name in ["Meetings", "VoicePrints", "WhisperModels"] {
            try manager.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        // How earlier versions left it: the whole folder out.
        try exclude(root)
        #expect(SupportFolder.isExcluded(root))
        #expect(SupportFolder.isExcluded(root.appendingPathComponent("dictionary.txt")))

        SupportFolder.applyBackupPolicy(to: root)

        #expect(settles { !SupportFolder.isExcluded(root) })
        #expect(settles { !SupportFolder.isExcluded(root.appendingPathComponent("dictionary.txt")) })
        #expect(settles { !SupportFolder.isExcluded(root.appendingPathComponent("dictionary.txt.bak")) })
        for name in ["history.sealed", "snippets.sealed", "Meetings", "VoicePrints", "WhisperModels", ".metadata_never_index"] {
            #expect(settles { SupportFolder.isExcluded(root.appendingPathComponent(name)) }, "\(name)")
        }
    }

    /// Clearing the exclusion lands on disk a moment later when the whole suite runs in
    /// parallel (seen as 1 run in 5 failing); Time Machine reads it much later still.
    /// Waits up to a second for the expected state.
    private func settles(_ condition: () -> Bool) -> Bool {
        for _ in 0..<50 {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    @Test func anAtomicRewriteIsPutBackOutOfTheBackup() throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let history = root.appendingPathComponent("history.sealed")
        try Data("a".utf8).write(to: history)
        SupportFolder.applyBackupPolicy(to: root)
        #expect(SupportFolder.isExcluded(history))

        // A new file replaces the old one and loses its exclusion.
        try Data("b".utf8).write(to: history, options: [.atomic])
        SupportFolder.keepOutOfBackup(history)
        #expect(SupportFolder.isExcluded(history))

        // The dictionary is never excluded, whoever asks.
        let dictionary = root.appendingPathComponent("dictionary.txt")
        try Data("Fluence".utf8).write(to: dictionary)
        SupportFolder.keepOutOfBackup(dictionary)
        #expect(!SupportFolder.isExcluded(dictionary))
    }
}
