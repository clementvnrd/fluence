import AVFoundation
import FluenceCore
import Foundation
import Security

/// FLU-113: the opt-in cloud engine, on top of the local engine the dictation would run on
/// anyway (Parakeet, or Apple while Parakeet is not on disk).
///
/// The local engine hears everything as usual, live text included; the same audio, kept at
/// 16 kHz, goes to the chosen provider once the key is released. The cloud's text wins when
/// it is back in time (`CloudFallback`); otherwise the local text is typed, as if the cloud
/// were off. Either way the stream carries one final snapshot, so a dictation is never typed
/// twice. If both fail, the stream throws and the controller's retry (`DictationRetry`) takes
/// the kept recording to another local engine.
actor CloudEngine: TranscriptionEngine {
    private let provider: CloudProvider
    /// Nil once it failed to start: the cloud alone then.
    private var local: (any TranscriptionEngine)?
    /// The local engine's last text, nil when it failed.
    private var localText: Task<String?, Never>?
    private var continuation: AsyncThrowingStream<TranscriptionChunk, Error>.Continuation?
    private var cloud: Task<String, Error>?

    private let converter = StreamConverter(output: RecordingReplay.format)
    private var samples: [Float] = []
    private var key: String?
    /// Why there is no key: none saved, or the Keychain would not give it (A2-8).
    private var noKey = CloudError.noKey
    private var language: String?
    private var terms: [String] = []

    /// After `finish()`: the history's engine name when the cloud's text was used.
    private(set) var producedBy: String?
    /// After `finish()`: why the local text was used instead, for the capsule.
    private(set) var fallback: CloudError?
    /// After `finish()`: who wrote the text, for the capsule's badge (FLU-129).
    private(set) var writer: CloudFallback.Writer?

    init(provider: CloudProvider, local: any TranscriptionEngine) {
        self.provider = provider
        self.local = local
    }

    func preferredInputFormat() async -> AVAudioFormat? {
        guard let local else { return RecordingReplay.format }
        return await local.preferredInputFormat()
    }

    func start() async throws -> AsyncThrowingStream<TranscriptionChunk, Error> {
        samples.removeAll(keepingCapacity: true)
        let (stream, continuation) = AsyncThrowingStream<TranscriptionChunk, Error>.makeStream()
        self.continuation = continuation
        (language, terms) = await MainActor.run {
            (Settings.shared.dictationLanguage.code, DictionaryStore.shared.biasPhrases(upTo: CloudProvider.termLimit))
        }
        do {
            key = try CloudKeys.shared.key(for: provider)
        } catch {
            noKey = .keychain
            Log.speech.error("cloud · key unreadable: \(error.localizedDescription, privacy: .public)")
            Diagnostics.error("speech.cloud.key", error)
        }
        if let local {
            do {
                let snapshots = try await local.start()
                localText = Task { await self.relay(snapshots) }
            } catch {
                Log.speech.error("cloud · local engine did not start: \(error.localizedDescription)")
                Diagnostics.error("speech.cloud.localStart", error)
                self.local = nil
                // Nothing to fall back on and nothing to send: fail as the local engine did.
                guard key != nil else { throw error }
            }
        }
        return stream
    }

    /// The local engine's live text goes on to the HUD; its last text is kept for the fallback.
    private func relay(_ snapshots: AsyncThrowingStream<TranscriptionChunk, Error>) async -> String? {
        var latest = ""
        do {
            for try await snapshot in snapshots {
                latest = snapshot.text
                if !snapshot.isFinal { continuation?.yield(snapshot) }
            }
            return latest
        } catch {
            Log.speech.error("cloud · local engine failed: \(error.localizedDescription)")
            return nil
        }
    }

    func feed(_ chunk: AudioChunk) async {
        await local?.feed(chunk)
        for buffer in converter.convert(chunk.buffer) { keep(buffer) }
    }

    private func keep(_ buffer: AVAudioPCMBuffer) {
        // A2-7: audio too long to send is not kept for the cloud either.
        guard let channel = buffer.floatChannelData?[0],
              CloudFallback.sends(audioSeconds: Double(samples.count) / RecordingReplay.format.sampleRate)
        else { return }
        samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    func finish() async {
        for buffer in converter.drain() { keep(buffer) }
        let rate = RecordingReplay.format.sampleRate
        let audioSeconds = Double(samples.count) / rate
        let sends = CloudFallback.sends(audioSeconds: audioSeconds)
        let started = ContinuousClock.now
        if let key, sends {
            let request = CloudRequest.transcription(
                key: key, wav: WAV.encode(samples, sampleRate: Int(rate)),
                language: language, terms: terms
            )
            cloud = Task { try await CloudClient.transcript(request) }
        }
        samples.removeAll()

        // The local engine finalises while the audio uploads. The cloud's text, back first,
        // does not wait for it (A2-11).
        let localDone = Task { await self.finishLocal() }
        let localText: String?
        let outcome: CloudFallback.Outcome?
        if let cloud, let early = await Self.text(of: cloud, before: localDone),
           !early.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await local?.cancel()
            localText = nil
            outcome = .text(early)
        } else if let cloud {
            localText = await localDone.value
            // With local text to fall back on, the cloud gets what is left of its deadline;
            // without, its own request timeout.
            let hasLocal = !(localText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let left = CloudFallback.deadline(audioSeconds: audioSeconds) - Self.seconds(since: started)
            outcome = await CloudClient.outcome(of: cloud, within: hasLocal ? left : nil)
        } else {
            localText = await localDone.value
            if key != nil, !sends {
                Log.speech.info("cloud · not sent: \(audioSeconds, format: .fixed(precision: 0))s of audio is too long")
            }
            outcome = .failed(key == nil ? noKey : .timedOut)
        }
        let elapsed = Self.seconds(since: started)

        let choice = CloudFallback.choose(cloud: outcome, local: localText)
        writer = choice.writer
        switch choice {
        case .cloud(let text):
            producedBy = "\(provider.displayName) (cloud)"
            let name = provider.rawValue
            Log.speech.info("cloud · \(name, privacy: .public) · \(audioSeconds, format: .fixed(precision: 1))s audio in \(elapsed, format: .fixed(precision: 2))s · \(text.count, privacy: .public) chars")
            continuation?.yield(TranscriptionChunk(text: text, isFinal: true))
        case .local(let text, let because):
            fallback = because
            let why = because?.kind ?? "empty cloud answer"
            Log.speech.info("cloud · local text used (\(why, privacy: .public)) after \(elapsed, format: .fixed(precision: 2))s")
            if because != nil { Diagnostics.recovery("speech.cloud.fallback") }
            continuation?.yield(TranscriptionChunk(text: text, isFinal: true))
        case .failed(let error):
            Log.speech.error("cloud · no text from the cloud (\(error.kind, privacy: .public)) nor the local engine")
            Diagnostics.error("speech.cloud.failed", error)
            continuation?.finish(throwing: error)
            continuation = nil
        }
        continuation?.finish()
        continuation = nil
    }

    private func finishLocal() async -> String? {
        await local?.finish()
        return await localText?.value ?? nil
    }

    /// The cloud's text when it is back before `other` ends; nil when `other` ends first or
    /// the cloud failed. Neither task is cancelled here.
    private static func text(of cloud: Task<String, Error>, before other: Task<String?, Never>) async -> String? {
        let (first, sink) = AsyncStream<String?>.makeStream()
        Task { sink.yield(try? await cloud.value) }
        Task { _ = await other.value; sink.yield(nil) }
        for await text in first { return text }
        return nil
    }

    func cancel() async {
        cloud?.cancel()
        samples.removeAll()
        continuation?.finish()
        continuation = nil
        await local?.cancel()
    }

    private static func seconds(since start: ContinuousClock.Instant) -> Double {
        let parts = (ContinuousClock.now - start).components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// The requests to ElevenLabs. An ephemeral session: no cache, cookie or credential of
/// these requests ever reaches the disk. Only status codes and timings are logged; a body
/// holds dictated text either way.
enum CloudClient {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        // The longest a dictation waits on the cloud when the local engine has nothing.
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration)
    }()

    static func send(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        do {
            let (body, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let host = request.url?.host() ?? ""
            Log.speech.info("cloud · \(host, privacy: .public) · HTTP \(status, privacy: .public)")
            return (status, body)
        } catch {
            throw CloudError.network
        }
    }

    static func transcript(_ request: URLRequest) async throws -> String {
        let (status, body) = try await send(request)
        return try CloudResponse.transcript(status: status, body: body)
    }

    /// The task's answer, or nil once `seconds` have passed, when it is cancelled. Nil
    /// `seconds`: as long as the request itself lasts.
    static func outcome(of task: Task<String, Error>, within seconds: Double?) async -> CloudFallback.Outcome? {
        let timer = seconds.map { limit in
            Task {
                try await Task.sleep(for: .seconds(max(0, limit)))
                task.cancel()
            }
        }
        defer { timer?.cancel() }
        do {
            return .text(try await task.value)
        } catch {
            if task.isCancelled { return nil }
            return .failed(error as? CloudError ?? .network)
        }
    }

    /// « Tester »: one second of silence with the saved key. Nil when the provider answered.
    static func test(_ provider: CloudProvider) async -> CloudError? {
        guard let key = try? CloudKeys.shared.key(for: provider) else { return .noKey }
        let silence = WAV.encode([Float](repeating: 0, count: 16_000), sampleRate: 16_000)
        let request = CloudRequest.transcription(key: key, wav: silence, language: nil, terms: [])
        do {
            _ = try await transcript(request)
            return nil
        } catch {
            return error as? CloudError ?? .network
        }
    }
}

/// The API keys in the login Keychain, beside the Vault's key: one item per provider, only
/// while the Mac has been unlocked once, never synced or migrated.
struct KeychainSecretStore: SecretStore {
    let service: String

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    func read(_ account: String) throws -> String? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else { throw Vault.Failure.corrupt }
            return String(decoding: data, as: UTF8.self)
        case errSecItemNotFound:
            return nil
        default:
            throw Vault.Failure.keychain(status)
        }
    }

    func write(_ value: String, account: String) throws {
        let data = Data(value.utf8)
        let updated = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        guard updated == errSecItemNotFound else {
            guard updated == errSecSuccess else { throw Vault.Failure.keychain(updated) }
            return
        }
        var attributes = query(account)
        attributes[kSecAttrLabel as String] = "Fluence – clé \(account)"
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecAttrSynchronizable as String] = false
        attributes[kSecValueData as String] = data
        let added = SecItemAdd(attributes as CFDictionary, nil)
        guard added == errSecSuccess else { throw Vault.Failure.keychain(added) }
    }

    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Vault.Failure.keychain(status) }
    }
}

extension CloudKeys {
    /// The self-test's scratch account never touches the Keychain (FLU-35), as for the Vault.
    static let shared = CloudKeys(
        store: SelfTest.isRequested
            ? InMemorySecretStore()
            : KeychainSecretStore(service: (Bundle.main.bundleIdentifier ?? "fluence") + ".cloud")
    )
}
