import CryptoKit
import Foundation

/// Meeting audio on disk, encrypted, appended as it is captured — never one growing
/// `[Float]` in memory.
///
/// One file per channel, `<meeting dir>/audio-mic.enc` and `audio-system.enc`, sealed with
/// the meeting's own key (`MeetingStore.meetingKey(for:create:)`), so deleting the meeting
/// makes its audio unreadable. Deleted after the final pass unless `meeting.keepAudio`.
///
/// Sample *i* is meeting time *i / 16 000* (the channel pipeline writes the aligned
/// timeline, silence included), which is what lets the diarizer read it by time.
///
/// Format (little-endian):
/// ```
/// header   "FLSP" | version u32 = 1 | sampleRate u32 | samplesPerRecord u32
/// record*  sealedLength u32 | AES-256-GCM combined box (nonce | ciphertext | tag)
///          of samplesPerRecord Int16 PCM samples (the last record may hold fewer)
/// ```
/// Every full record has the same size, so a record is found by arithmetic. A record cut
/// short by a crash fails authentication and is ignored.
final class MeetingAudioSpool: @unchecked Sendable {
    static let magic = Data("FLSP".utf8)
    static let version: UInt32 = 1
    static let headerSize = 16
    static let samplesPerRecord = 16_000

    static func url(in directory: URL, source: AudioSource) -> URL {
        directory.appendingPathComponent(source == .microphone ? "audio-mic.enc" : "audio-system.enc")
    }

    private let handle: FileHandle
    private let key: SymmetricKey
    private var pending: [Int16] = []
    private(set) var sampleCount = 0
    private let lock = NSLock()

    init(url: URL, key: SymmetricKey) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        handle = try FileHandle(forWritingTo: url)
        try handle.truncate(atOffset: 0)
        self.key = key

        var header = Self.magic
        header.appendLittleEndian(Self.version)
        header.appendLittleEndian(UInt32(MeetingAudioFormat.sampleRate))
        header.appendLittleEndian(UInt32(Self.samplesPerRecord))
        try handle.write(contentsOf: header)
        pending.reserveCapacity(Self.samplesPerRecord)
    }

    /// Appends samples; full records are sealed and written immediately, so at most one
    /// second per channel is ever held in memory.
    func append(_ samples: [Float]) throws {
        lock.lock()
        defer { lock.unlock() }
        for sample in samples {
            pending.append(Int16(max(-1, min(1, sample)) * Float(Int16.max)))
            if pending.count == Self.samplesPerRecord {
                try writeRecord()
            }
        }
        sampleCount += samples.count
    }

    func appendSilence(_ count: Int) throws {
        guard count > 0 else { return }
        var remaining = count
        while remaining > 0 {
            let chunk = min(remaining, Self.samplesPerRecord)
            try append([Float](repeating: 0, count: chunk))
            remaining -= chunk
        }
    }

    /// Writes the last partial record and closes the file.
    func close() throws {
        lock.lock()
        defer { lock.unlock() }
        if !pending.isEmpty { try writeRecord() }
        try handle.close()
    }

    private func writeRecord() throws {
        let plaintext = pending.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: buffer.count * MemoryLayout<Int16>.size)
        }
        let sealed = try Vault.seal(plaintext, with: key)
        var record = Data()
        record.appendLittleEndian(UInt32(sealed.count))
        record.append(sealed)
        try handle.write(contentsOf: record)
        pending.removeAll(keepingCapacity: true)
    }
}

/// Random access to a spool file. Thread-safe; caches the last decrypted record, which is
/// what sequential readers (the diarizer walks in 10 s windows) hit almost every time.
final class MeetingAudioSpoolReader: @unchecked Sendable {
    enum Failure: Error {
        case notASpool
    }

    let sampleCount: Int
    private let handle: FileHandle
    private let key: SymmetricKey
    private let samplesPerRecord: Int
    private let fullRecordSize: Int
    private let lock = NSLock()
    private var cachedIndex = -1
    private var cached: [Int16] = []

    init(url: URL, key: SymmetricKey) throws {
        handle = try FileHandle(forReadingFrom: url)
        self.key = key
        let header = try handle.read(upToCount: MeetingAudioSpool.headerSize) ?? Data()
        guard header.count == MeetingAudioSpool.headerSize, header.prefix(4) == MeetingAudioSpool.magic else {
            throw Failure.notASpool
        }
        samplesPerRecord = Int(header.littleEndianUInt32(at: 12))
        guard samplesPerRecord > 0 else { throw Failure.notASpool }
        // 4-byte length + 12-byte nonce + payload + 16-byte tag.
        fullRecordSize = 4 + 12 + samplesPerRecord * 2 + 16

        let size = Int(try handle.seekToEnd())
        let body = max(0, size - MeetingAudioSpool.headerSize)
        var count = (body / fullRecordSize) * samplesPerRecord
        let tail = body % fullRecordSize
        if tail > 4 + 28 {
            // A partial last record: its own length field says how much it holds.
            try handle.seek(toOffset: UInt64(MeetingAudioSpool.headerSize + (body / fullRecordSize) * fullRecordSize))
            if let lengthData = try handle.read(upToCount: 4), lengthData.count == 4 {
                let sealed = Int(lengthData.littleEndianUInt32(at: 0))
                if sealed <= tail - 4, sealed > 28 { count += (sealed - 28) / 2 }
            }
        }
        sampleCount = count
    }

    deinit {
        try? handle.close()
    }

    /// Copies samples `[offset, offset + count)` as Float; positions past the end (or in a
    /// damaged record) read as silence.
    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) {
        lock.lock()
        defer { lock.unlock() }
        var written = 0
        while written < count {
            let position = offset + written
            let index = position / samplesPerRecord
            let within = position % samplesPerRecord
            let record = position < sampleCount ? self.record(index) : []
            let available = max(0, min(record.count - within, count - written))
            if available == 0 {
                // Silence up to the next record boundary (or the end of the request).
                let gap = min(samplesPerRecord - within, count - written)
                (destination + written).update(repeating: 0, count: gap)
                written += gap
                continue
            }
            for i in 0..<available {
                destination[written + i] = Float(record[within + i]) / Float(Int16.max)
            }
            written += available
        }
    }

    func samples(from offset: Int, count: Int) -> [Float] {
        guard count > 0 else { return [] }
        var result = [Float](repeating: 0, count: count)
        result.withUnsafeMutableBufferPointer { copySamples(into: $0.baseAddress!, offset: offset, count: count) }
        return result
    }

    private func record(_ index: Int) -> [Int16] {
        if index == cachedIndex { return cached }
        cachedIndex = index
        cached = []
        do {
            try handle.seek(toOffset: UInt64(MeetingAudioSpool.headerSize + index * fullRecordSize))
            guard let lengthData = try handle.read(upToCount: 4), lengthData.count == 4 else { return [] }
            let length = Int(lengthData.littleEndianUInt32(at: 0))
            guard length > 28, length <= fullRecordSize - 4,
                  let sealed = try handle.read(upToCount: length), sealed.count == length
            else { return [] }
            let plaintext = try Vault.open(sealed, with: key)
            cached = plaintext.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        } catch {
            Log.audio.error("spool record \(index) unreadable")
        }
        return cached
    }
}

fileprivate extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    func littleEndianUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<4 {
            value |= UInt32(self[startIndex + offset + i]) << (8 * i)
        }
        return value
    }
}
