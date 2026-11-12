import Foundation

// FLU-113: the opt-in cloud engine. Off by default; on, the audio of each dictation goes to
// ElevenLabs (Scribe v3), with the user's own key. Everything here builds or reads bytes;
// nothing here touches the network, the Keychain or a log.

/// Where the audio goes. A stored value of a removed provider (« mistral », dev builds) reads as off.
public enum CloudProvider: String, CaseIterable, Sendable {
    case elevenLabs = "elevenlabs"

    public var displayName: String { "ElevenLabs" }

    /// Past 100 terms ElevenLabs bills 20 s minimum per request.
    static let termLimit = 100
}

/// Why the cloud gave no text. Made from the HTTP status or the transport alone: a response
/// body can hold the dictation, so it is never kept, shown or logged.
public enum CloudError: Error, Equatable, Sendable {
    /// No key saved for the provider.
    case noKey
    /// 401 / 403.
    case badKey
    case rateLimited
    case server(Int)
    /// Any other refusal (a 422 on a malformed request).
    case rejected(Int)
    /// A 2xx without the expected text.
    case malformed
    /// No connection, DNS, TLS, the request's own timeout.
    case network
    /// Not back within `CloudFallback.deadline`.
    case timedOut

    /// For the log: fixed words and a status, nothing else.
    public var kind: String {
        switch self {
        case .noKey: "no key"
        case .badKey: "bad key"
        case .rateLimited: "rate limited"
        case .server(let status): "server \(status)"
        case .rejected(let status): "rejected \(status)"
        case .malformed: "malformed answer"
        case .network: "network"
        case .timedOut: "timed out"
        }
    }

    /// Worth one more try after a pause (FLU-132): a busy or failing server, not a refusal.
    public var isTransient: Bool {
        switch self {
        case .rateLimited, .server: true
        default: false
        }
    }
}

public enum CloudRequest {
    /// Pinned, so a « latest » alias never changes behaviour under us.
    static let elevenLabsModel = "scribe_v3"

    /// One dictation's audio for ElevenLabs' batch endpoint.
    /// - Parameters:
    ///   - language: ISO 639-1 (`DictationLanguage.code`); nil lets the provider detect it.
    ///   - terms: the dictionary's spellings, the user's own first (`biasPhrases`).
    public static func transcription(
        key: String,
        wav: Data,
        language: String?,
        terms: [String],
        boundary: String = "fluence-" + UUID().uuidString
    ) -> URLRequest {
        var request = post(key: key, boundary: boundary)
        var fields = [("model_id", elevenLabsModel)]
        if let language { fields.append(("language_code", language)) }
        // « (rires) » has no place in typed text.
        fields.append(("tag_audio_events", "false"))
        fields += Self.terms(terms).map { ("keyterms", $0) }
        request.httpBody = multipart(fields, file: wav, name: "audio.wav", type: "audio/wav", boundary: boundary)
        return request
    }

    /// FLU-132: one channel of a finished meeting, with word timings, and its voices told apart
    /// when `diarize` (the call's channel; the mic is the user). The spool's own samples go as
    /// they are — 16 kHz 16-bit mono PCM, no codec, nothing written to disk — about 115 MB an
    /// hour. Neither the language (a meeting is not always in the dictation's) nor the count of
    /// voices (rarely known for sure, FLU-33) is sent: the provider finds both.
    /// The body comes apart from the request, for `URLSession.upload(for:from:)`.
    public static func meeting(
        key: String,
        pcm: Data,
        diarize: Bool,
        terms: [String],
        boundary: String = "fluence-" + UUID().uuidString
    ) -> (request: URLRequest, body: Data) {
        var fields = [
            ("model_id", elevenLabsModel),
            ("tag_audio_events", "false"),
            ("timestamps_granularity", "word"),
            ("diarize", diarize ? "true" : "false"),
            ("file_format", "pcm_s16le_16"),
        ]
        fields += Self.terms(terms).map { ("keyterms", $0) }
        let body = multipart(fields, file: pcm, name: "audio.pcm", type: "application/octet-stream", boundary: boundary)
        return (post(key: key, boundary: boundary), body)
    }

    private static func post(key: String, boundary: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!)
        request.httpMethod = "POST"
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    /// The terms ElevenLabs accepts, in order, at most `termLimit`. It refuses the whole
    /// request (422) for one term over 50 characters, over five words or with `<>{}[]\`.
    public static func terms(_ terms: [String]) -> [String] {
        let refused = CharacterSet(charactersIn: "<>{}[]\\")
        let kept = terms.filter { term in
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmed.isEmpty
                && trimmed.count <= 50
                && trimmed.split(whereSeparator: \.isWhitespace).count <= 5
                && trimmed.rangeOfCharacter(from: refused) == nil
        }
        return Array(kept.prefix(CloudProvider.termLimit))
    }

    private static func multipart(_ fields: [(String, String)], file: Data, name fileName: String, type: String, boundary: String) -> Data {
        var body = Data()
        body.reserveCapacity(file.count + 4096)
        for (name, value) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: \(type)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

public enum CloudResponse {
    /// The transcript of a transcription answer, in `text`.
    public static func transcript(status: Int, body: Data) throws -> String {
        try check(status)
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let text = json["text"] as? String
        else { throw CloudError.malformed }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The error an HTTP status means, from the status alone (the body is never read for it).
    public static func check(_ status: Int) throws {
        switch status {
        case 200..<300: return
        case 401, 403: throw CloudError.badKey
        case 429: throw CloudError.rateLimited
        case 500...: throw CloudError.server(status)
        default: throw CloudError.rejected(status)
        }
    }
}

/// Which text a dictation types when the cloud engine is on: the cloud's when it answers in
/// time, the local engine's otherwise. The local engine runs on the same audio meanwhile, so
/// falling back costs nothing but the wait.
public enum CloudFallback {
    /// Seconds after the end of the recording the cloud's answer is waited for, once the
    /// local text is ready. 2.5 s covers a short dictation's upload and transcription with
    /// room to spare (Wispr Flow answers in about 1.5 s); each second of audio adds 0.1 s of
    /// upload and server time (32 KB a second of 16 kHz WAV). Capped at 8 s: past that a
    /// long dictation is better typed from the Mac than waited for.
    public static func deadline(audioSeconds: Double) -> Double {
        min(2.5 + 0.1 * max(0, audioSeconds), 8)
    }

    /// FLU-132: how long one channel of a finished meeting may take, upload included, before
    /// the Mac transcribes it instead: a minute, plus half the audio's length (115 MB an hour
    /// to upload), at most 30 minutes.
    public static func meetingDeadline(audioSeconds: Double) -> Double {
        min(60 + 0.5 * max(0, audioSeconds), 1800)
    }

    public enum Outcome: Equatable, Sendable {
        case text(String)
        case failed(CloudError)
    }

    public enum Choice: Equatable, Sendable {
        case cloud(String)
        /// The local text; `because` is what the capsule says, nil to say nothing.
        case local(String, because: CloudError?)
        case failed(CloudError)

        /// FLU-129: who wrote the text, for the capsule's badge; nil when there is none.
        public var writer: Writer? {
            switch self {
            case .cloud: .cloud
            case .local: .mac
            case .failed: nil
            }
        }
    }

    /// FLU-129: who wrote a dictation's text.
    public enum Writer: Equatable, Sendable { case cloud, mac }

    /// FLU-129: how much longer than before the capsule stays once the text is typed, so the
    /// badge is seen (Clement: 0.4 s). None when a message follows, which shows for its own
    /// time, nor without a badge (cloud off).
    public static func badgeHold(writer: Writer?, messageFollows: Bool) -> Double {
        writer == nil || messageFollows ? 0 : 0.4
    }

    /// - Parameters:
    ///   - cloud: the cloud's answer, nil when it did not come back in time. Without local
    ///     text the engine waits for it as long as the request lasts.
    ///   - local: the local engine's text, nil when it failed.
    public static func choose(cloud: Outcome?, local: String?) -> Choice {
        let local = local.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        switch (cloud, local) {
        case (.text(let text)?, _) where !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return .cloud(text)
        case (.text?, let local?):
            return .local(local, because: nil)
        case (.text(let text)?, nil):
            return .cloud(text)
        case (.failed(let error)?, let local?):
            return .local(local, because: error)
        case (nil, let local?):
            return .local(local, because: .timedOut)
        case (nil, nil):
            return .failed(.timedOut)
        case (.failed(let error)?, nil):
            return .failed(error)
        }
    }

    /// What the capsule says over a dictation typed from the local engine.
    public static func notice(_ error: CloudError, local engine: String) -> String {
        let reason = switch error {
        case .network: "Hors ligne"
        case .noKey: "Aucune clé"
        case .badKey: "Clé refusée"
        case .timedOut: "Cloud trop lent"
        case .rateLimited, .server, .rejected, .malformed: "Cloud indisponible"
        }
        return reason + FrenchFormat.space + ": " + engine
    }
}

/// 16-bit PCM WAV, mono, in memory: a format ElevenLabs takes without a codec.
public enum WAV {
    public static func encode(_ samples: [Float], sampleRate: Int) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = Data(capacity: 44 + Int(dataSize))
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(Data("RIFF".utf8)); append(36 + dataSize)
        data.append(Data("WAVEfmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))  // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))  // block align, bits
        data.append(Data("data".utf8)); append(dataSize)
        for sample in samples {
            append(Int16((max(-1, min(1, sample)) * 32_767).rounded()))
        }
        return data
    }
}

// MARK: - Keys

/// Where the API keys are kept: the Keychain in the app, memory in tests and the self-test.
public protocol SecretStore: Sendable {
    func read(_ account: String) throws -> String?
    /// Adds or replaces.
    func write(_ value: String, account: String) throws
    func delete(_ account: String) throws
}

public final class InMemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    public init() {}

    public func read(_ account: String) throws -> String? { lock.withLock { values[account] } }
    public func write(_ value: String, account: String) throws { lock.withLock { values[account] = value } }
    public func delete(_ account: String) throws { _ = lock.withLock { values.removeValue(forKey: account) } }
}

/// The user's API keys, one per provider, read from the store once and kept in memory, so a
/// key-down never waits on the Keychain. Never written anywhere else, never logged.
public final class CloudKeys: @unchecked Sendable {
    public enum Failure: Error, Equatable { case empty }

    private let store: any SecretStore
    private let lock = NSLock()
    private var cache: [CloudProvider: String?] = [:]

    public init(store: any SecretStore) {
        self.store = store
    }

    public func key(for provider: CloudProvider) throws -> String? {
        try lock.withLock {
            if let cached = cache[provider] { return cached }
            let key = try store.read(provider.rawValue)
            cache[provider] = .some(key)
            return key
        }
    }

    public func has(_ provider: CloudProvider) -> Bool {
        ((try? key(for: provider)) ?? nil) != nil
    }

    /// A pasted key often carries a space or a line break: they are not part of it.
    public func save(_ raw: String, for provider: CloudProvider) throws {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw Failure.empty }
        try lock.withLock {
            try store.write(key, account: provider.rawValue)
            cache[provider] = .some(key)
        }
    }

    public func remove(_ provider: CloudProvider) throws {
        try lock.withLock {
            try store.delete(provider.rawValue)
            cache[provider] = .some(nil)
        }
    }
}

