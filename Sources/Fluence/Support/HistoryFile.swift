import CryptoKit
import FluenceCore
import Foundation

/// The history on disk: `history.sealed`, one AES-GCM-sealed JSON run per line.
///
/// Every operation runs on one serial queue, in the order it was submitted, so an append can
/// never overtake the rewrite a delete queued just before it. Rewrites read the *file*, not
/// the in-memory list, which is what keeps the two from disagreeing about what exists.
///
/// The one rule that matters: **if the Vault can't produce a key, nothing is written.** A
/// Keychain refusal skips the save and reports it; it never falls back to plaintext, and it
/// never rewrites the file with what little it could read.
final class HistoryFile: @unchecked Sendable {
    static let shared = HistoryFile()

    enum LoadResult: Sendable {
        /// The runs, and how many lines did not open (kept as they are).
        case success([DictationRun], unreadable: Int)
        case failure(String)
    }

    /// Hands a result back on the main actor.
    typealias Report = @MainActor @Sendable (String?) -> Void

    private let queue = DispatchQueue(label: "history-file", qos: .utility)

    private var directory: URL { AppPaths.support }
    private var url: URL { directory.appendingPathComponent("history.sealed") }

    /// The plaintext files of earlier versions — removed once their contents are sealed.
    private var legacyRuns: URL { directory.appendingPathComponent("runs.jsonl") }
    private var legacyDashboard: URL { directory.appendingPathComponent("dashboard.html") }

    private init() {}

    // MARK: - Operations

    func load(then completion: @escaping @MainActor @Sendable (LoadResult) -> Void) {
        queue.async {
            let result: LoadResult
            do {
                try self.migrateLegacyFile()
                let key = try Vault.masterKey()
                let contents = try self.read(with: key)
                result = .success(contents.runs, unreadable: contents.unreadable.count)
            } catch {
                result = .failure(Self.message("L'historique n'a pas pu être ouvert", error))
            }
            Task { @MainActor in completion(result) }
        }
    }

    func append(_ run: DictationRun, then report: @escaping Report) {
        withKey { key in
            let line = try SealedLines.line(for: try Self.encode(run)) { try Vault.seal($0, with: key) }
            try self.appendLine(line)
        } then: { report($0.map { Self.message("L'historique n'est pas enregistré", $0) }) }
    }

    func remove(where predicate: @escaping @Sendable (DictationRun) -> Bool, then report: @escaping Report) {
        withKey { key in
            let current = try self.read(with: key)
            let kept = current.runs.filter { !predicate($0) }
            guard kept.count != current.runs.count else { return }
            try self.rewrite(kept, preserving: current.unreadable, with: key)
        } then: { report($0.map { Self.message("L'historique n'a pas pu être mis à jour", $0) }) }
    }

    func purge(_ retention: HistoryRetention, now: Date, then report: @escaping Report) {
        guard retention.persists else {
            clear(then: report)
            return
        }
        guard retention.cutoff(now: now) != nil else { return }
        remove(where: { !retention.keeps($0.date, now: now) }, then: report)
    }

    /// Needs no key: removing the file is always possible, and must stay possible when the
    /// Keychain is the thing that's broken.
    func clear(then report: @escaping Report) {
        queue.async {
            var problem: String?
            for file in [self.url, self.legacyRuns, self.legacyDashboard] + LegacyMigration.legacyRunFiles(in: self.directory) {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch CocoaError.fileNoSuchFile {
                    continue
                } catch {
                    problem = "L'historique n'a pas pu être supprimé : \(Self.describe(error))"
                }
            }
            Task { @MainActor in report(problem) }
        }
    }

    // MARK: - Queue plumbing

    /// Runs `work` on the queue with the master key, reporting the outcome on the main actor.
    /// Without a key, `work` never runs.
    private func withKey(
        _ work: @escaping @Sendable (SymmetricKey) throws -> Void,
        then report: @escaping @MainActor @Sendable (Error?) -> Void
    ) {
        queue.async {
            var problem: Error?
            do {
                try work(try Vault.masterKey())
            } catch {
                problem = error
            }
            Task { @MainActor [problem] in report(problem) }
        }
    }

    /// Runs `work` on the history's queue, after every operation submitted before it and
    /// before any submitted after: a fresh start or a restore rewrites the file under the
    /// app, so no append may interleave (FLU-36).
    func exclusively(_ work: @escaping @Sendable () -> Void) {
        queue.async(execute: work)
    }

    // MARK: - File access (queue only)

    private struct Contents {
        var runs: [DictationRun] = []
        /// Lines this key couldn't open, carried through rewrites untouched.
        var unreadable: [Data] = []
    }

    private func read(with key: SymmetricKey) throws -> Contents {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch CocoaError.fileReadNoSuchFile {
            return Contents()
        }

        let decoded = SealedLines.decode(data) { try Vault.open($0, with: key) }
        var contents = Contents(unreadable: decoded.unreadable)
        for record in decoded.records {
            // Sealed but not a run this version understands: keep the bytes rather than
            // dropping them on the next rewrite.
            if let run = try? Self.decoder().decode(DictationRun.self, from: record) {
                contents.runs.append(run)
            } else {
                let resealed = try SealedLines.line(for: record) { try Vault.seal($0, with: key) }
                contents.unreadable.append(resealed.dropLast()) // without its newline
            }
        }
        if !contents.unreadable.isEmpty {
            Log.app.error("history: \(contents.unreadable.count, privacy: .public) line(s) could not be opened and were kept as-is")
            Diagnostics.error("history.unreadableLines")
        }
        return contents
    }

    private func rewrite(_ runs: [DictationRun], preserving unreadable: [Data], with key: SymmetricKey) throws {
        let records = try runs.map(Self.encode)
        let file = try SealedLines.file(records: records, preserving: unreadable) {
            try Vault.seal($0, with: key)
        }
        // Atomic: a torn rewrite would lose history the user didn't ask to delete.
        try file.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        AppPaths.keepOutOfBackup(url)
    }

    /// Restores a missing newline first: a torn last line must not swallow this one (R11).
    private func appendLine(_ line: Data) throws {
        try SealedLogFile.append(line, to: url)
        AppPaths.keepOutOfBackup(url)  // when this append created the file
    }

    /// One-time move from the plaintext `runs.jsonl` files (and the HTML copy rendered
    /// beside them) to the sealed file — `Fluence/runs.jsonl`, and Clement's
    /// `MurmurYouTube/runs.jsonl` when it is still there (FLU-11, `LegacyMigration`).
    ///
    /// Each plaintext file is deleted only after its runs are safely sealed. If the Keychain
    /// refuses, it stays exactly where it was and the move is retried on the next launch —
    /// never half-done, and never by writing anything new in plaintext. A line this version
    /// can't decode is sealed as it is, kept with the other unreadable lines, rather than
    /// lost with the plaintext.
    private func migrateLegacyFile() throws {
        let manager = FileManager.default
        // The dashboard is a rendered copy of runs.jsonl, never a source: always safe to drop.
        try? manager.removeItem(at: legacyDashboard)

        for file in LegacyMigration.legacyRunFiles(in: directory) {
            guard let legacy = try? Data(contentsOf: file) else { continue }
            let key = try Vault.masterKey()
            let decoder = Self.decoder()

            // A previous attempt may have sealed these and then failed to delete the
            // plaintext; matching on date and text keeps that from duplicating them.
            let existing = try read(with: key)
            let plan = LegacyMerge.importHistory(
                legacy,
                alreadySealed: Set(existing.runs.map(Self.identity)),
                identity: { line in (try? decoder.decode(DictationRun.self, from: line)).map(Self.identity) }
            )
            let fresh = plan.fresh.compactMap { try? decoder.decode(DictationRun.self, from: $0) }
            let kept = try plan.unreadable.map { raw in
                try SealedLines.line(for: raw) { try Vault.seal($0, with: key) }.dropLast()
            }

            try rewrite(fresh + existing.runs, preserving: existing.unreadable + kept, with: key)
            try manager.removeItem(at: file)
            Log.app.info("""
                history: sealed \(fresh.count, privacy: .public) run(s) from a plaintext runs.jsonl \
                (\(kept.count, privacy: .public) undecodable kept sealed) and removed the plaintext
                """)
        }
        LegacyMigration.removeIfEmpty(LegacyMigration.legacySupport)
    }

    private static func identity(_ run: DictationRun) -> String {
        "\(run.date.timeIntervalSince1970)|\(run.text)"
    }

    // MARK: - Coding

    private static func encode(_ run: DictationRun) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(run)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// `prefix : cause`, except for a lost key, which says what happened in one sentence.
    private static func message(_ prefix: String, _ error: Error) -> String {
        if case VaultKeyError.keyLost? = error as? VaultKeyError { return Vault.keyLostMessage }
        return "\(prefix) : \(describe(error))"
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? Vault.Failure { return failure.description }
        return error.localizedDescription
    }
}
