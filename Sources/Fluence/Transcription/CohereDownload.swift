import CryptoKit
import FluenceCore
import Foundation
import Observation

/// Cohere Transcribe's download (FLU-149), asked for and watched like Parakeet's: about 1,5 Go
/// fetched only on the user's click in Réglages › Transcription, never at a key-down. Files of
/// the pinned revision come from Hugging Face one by one, each checked against its SHA-256
/// before it takes its place; a file that fails the check is deleted.
@MainActor
@Observable
final class CohereDownload {
    static let shared = CohereDownload()

    private(set) var phase: ModelDownloadPhase = .idle
    /// The model is complete on disk. Read from the disk at launch, after a download, and on
    /// `refresh()`; views read this, never the disk.
    private(set) var isReady: Bool

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var attempt = 0

    private init() {
        isReady = CohereModels.isDownloaded
    }

    var isDownloading: Bool {
        if case .downloading = phase { return true }
        return false
    }

    @discardableResult
    func refresh() -> Bool {
        isReady = CohereModels.isDownloaded
        return isReady
    }

    func start() {
        guard task == nil, !refresh() else { return }
        phase = .downloading(0)
        attempt += 1
        let attempt = self.attempt
        Log.speech.info("Cohere: download started (asked for)")
        task = Task {
            do {
                try await Self.download { fraction in
                    Task { @MainActor in CohereDownload.shared.progressed(fraction, attempt: attempt) }
                }
                self.finished(nil, attempt: attempt)
            } catch {
                self.finished(error, attempt: attempt)
            }
        }
    }

    /// ✕: stops the download. Files already checked stay; the one under way starts over.
    func cancel() {
        guard let task else { return }
        task.cancel()
        self.task = nil
        phase = .idle
        Log.speech.info("Cohere: download cancelled")
    }

    private func progressed(_ fraction: Double, attempt: Int) {
        guard attempt == self.attempt, task != nil, case .downloading(let shown) = phase else { return }
        phase = .downloading(max(shown, fraction))
    }

    private func finished(_ error: Error?, attempt: Int) {
        guard attempt == self.attempt, task != nil else { return }
        task = nil
        if let error {
            Log.speech.error("Cohere: download failed — \(String(describing: type(of: error)), privacy: .public)")
            Diagnostics.error("speech.cohere.download", error)
            phase = .failed
            refresh()
            return
        }
        phase = .idle
        if refresh() {
            Log.speech.info("Cohere: download complete")
            Settings.shared.prewarmCurrentEngine()
        } else {
            Log.speech.error("Cohere: download ended but the model folder is incomplete")
            Diagnostics.error("speech.cohere.incomplete")
            phase = .failed
        }
    }

    enum DownloadError: Error {
        case badStatus(Int)
        case checksumMismatch(String)
    }

    /// Fetches the files that are not there at their full size, reporting 0…1 of all bytes.
    private nonisolated static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let folder = CohereModels.folder
        // Owner-only, out of Time Machine and Spotlight, like every folder of the support folder.
        AppPaths.protect(folder)
        let total = Double(CohereModel.totalBytes)
        var done: Int64 = 0
        for file in CohereModel.files {
            let destination = folder.appendingPathComponent(file.name)
            let size = (try? FileManager.default.attributesOfItem(atPath: destination.path))?[.size] as? Int64
            if size != file.bytes {
                let base = done
                let fetched = try await fetch(CohereModel.url(for: file)) { written in
                    progress(Double(base + written) / total)
                }
                defer { try? FileManager.default.removeItem(at: fetched) }
                let digest = try sha256(of: fetched)
                guard digest == file.sha256 else { throw DownloadError.checksumMismatch(file.name) }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: fetched, to: destination)
            }
            done += file.bytes
            progress(Double(done) / total)
        }
    }

    /// One file into a temporary place in the model folder (same volume, so the final move is
    /// a rename). Cancelling the calling task cancels the transfer.
    private nonisolated static func fetch(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        let delegate = ProgressDelegate(progress: progress)
        let (temporary, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        guard let status = (response as? HTTPURLResponse)?.statusCode, status == 200 else {
            try? FileManager.default.removeItem(at: temporary)
            throw DownloadError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let staged = CohereModels.folder.appendingPathComponent(url.lastPathComponent + ".partial")
        try? FileManager.default.removeItem(at: staged)
        try FileManager.default.moveItem(at: temporary, to: staged)
        return staged
    }

    private nonisolated static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// Bytes written so far of one transfer.
private final class ProgressDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    let progress: @Sendable (Int64) -> Void

    init(progress: @escaping @Sendable (Int64) -> Void) {
        self.progress = progress
    }

    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
        progress(totalBytesWritten)
    }

    // Required by the protocol; the async `download(from:delegate:)` hands the file back itself.
    func urlSession(_: URLSession, downloadTask _: URLSessionDownloadTask, didFinishDownloadingTo _: URL) {}
}
