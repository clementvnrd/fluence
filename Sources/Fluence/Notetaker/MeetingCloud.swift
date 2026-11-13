import CryptoKit
import FluenceCore
import FluenceDictionary
import Foundation

/// FLU-132: a meeting recorded in Précis is transcribed by ElevenLabs (Scribe v3) before the
/// final pass: the call's channel, with its voices told apart. The mic is not sent: its spool is
/// raw, echo included, and its live segments are already echo-cancelled and the user's (A3-4).
/// The spool is decrypted in memory into the request body itself and uploaded from memory;
/// nothing plaintext reaches the disk. Any failure — no key, a refusal, the network, the
/// deadline, an odd answer — gives nil, and the Mac's own pass (local diarization of the live
/// transcript) runs as before. A quit during the upload leaves the recording marker: the next
/// launch's recovery tries again, then falls back the same way. Logs carry counts, sizes,
/// timings and HTTP statuses only.
enum MeetingCloud {
    struct Request: Sendable {
        let key: String
        let terms: [String]
    }

    struct Transcript: Sendable {
        var system: [TranscriptSegment]
        /// The provider's voices on the call's channel.
        var turns: [SpeakerTurn]
    }

    /// Précis with its key: what a meeting started now is recorded under, and what its texts say.
    @MainActor static var isOn: Bool {
        Settings.shared.anyCloud != nil
    }

    /// Nil unless the meeting was recorded in Précis (A3-11) and Précis still has a readable
    /// key (a fallback, recorded).
    @MainActor static func request(_ meeting: Meeting) -> Request? {
        guard meeting.cloudAllowed == true, let provider = Settings.shared.cloudProvider else { return nil }
        guard let key = try? CloudKeys.shared.key(for: provider) else {
            Log.speech.error("meeting cloud · no key: the Mac transcribes the meeting")
            Diagnostics.recovery("meeting.cloud.fallback", CloudError.noKey)
            return nil
        }
        return Request(key: key, terms: DictionaryStore.shared.biasPhrases)
    }

    /// The call's channel, or nil when it fails.
    static func transcribe(
        _ request: Request,
        system url: URL,
        key: SymmetricKey,
        live: [TranscriptSegment],
        corrector: DictionaryCorrector
    ) async -> Transcript? {
        do {
            let reader = try MeetingAudioSpoolReader(url: url, key: key)
            // ElevenLabs refuses under 100 ms of audio.
            guard reader.sampleCount >= MeetingAudioFormat.sampleRate / 10 else { return Transcript(system: live, turns: []) }
            let seconds = Double(reader.sampleCount) / Double(MeetingAudioFormat.sampleRate)
            let (urlRequest, body) = CloudRequest.meeting(key: request.key, terms: request.terms) { body in
                append(reader, to: &body)
            }
            let started = ContinuousClock.now
            let data = try await send(urlRequest, body: body, within: CloudFallback.meetingDeadline(audioSeconds: seconds))

            guard let words = CloudTranscript.words(json: data) else { throw CloudError.malformed }
            // The provider heard nothing where the Mac heard words: keep the Mac's.
            if words.isEmpty, live.contains(where: { !$0.text.isEmpty }) { throw CloudError.malformed }
            let (segments, turns) = CloudTranscript.channel(
                words, source: .system, speakerID: Speaker.othersID,
                transform: { corrector.apply(to: $0).text }
            )
            Log.speech.info("""
                meeting cloud · \(Int(seconds), privacy: .public)s audio, \
                \(body.count / 1_000_000, privacy: .public) MB, \((ContinuousClock.now - started).components.seconds, privacy: .public)s · \
                \(words.count, privacy: .public) words, \(segments.count, privacy: .public) segments, \
                \(Set(turns.map(\.speaker)).count, privacy: .public) voices
                """)
            return Transcript(system: segments, turns: turns)
        } catch {
            let kind = (error as? CloudError)?.kind ?? "spool unreadable"
            Log.speech.error("meeting cloud · \(kind, privacy: .public): the Mac transcribes the meeting")
            Diagnostics.recovery("meeting.cloud.fallback", error)
            return nil
        }
    }

    /// The spool's samples as 16-bit PCM, decrypted a minute at a time straight into `body`:
    /// the channel is held once, in the request body (A3-10).
    private static func append(_ reader: MeetingAudioSpoolReader, to body: inout Data) {
        body.reserveCapacity(body.count + reader.sampleCount * 2 + 256)
        let step = MeetingAudioFormat.sampleRate * 60
        var offset = 0
        while offset < reader.sampleCount {
            let count = min(step, reader.sampleCount - offset)
            // The spool's own Int16 values back (it stores `Int16(x · Int16.max)`).
            let samples = reader.samples(from: offset, count: count).map { Int16(($0 * Float(Int16.max)).rounded()).littleEndian }
            samples.withUnsafeBytes { body.append(contentsOf: $0) }
            offset += count
        }
    }

    /// Ephemeral: no cache, cookie or credential reaches the disk. The wait is bounded by the
    /// meeting's deadline in `send`; the session's own limits only stop a link that hangs.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // A long file is uploaded, then worked on with nothing coming back for a while.
        configuration.timeoutIntervalForRequest = 900
        configuration.timeoutIntervalForResource = 900
        return URLSession(configuration: configuration)
    }()

    /// One upload, and one more after 10 s on 429 / 5xx, all within `seconds` (A3-10).
    private static func send(_ request: URLRequest, body: Data, within seconds: Double) async throws -> Data {
        let task = Task { () async throws -> Data in
            do {
                return try await post(request, body: body)
            } catch let error as CloudError where error.isTransient {
                try await Task.sleep(for: .seconds(10))
                return try await post(request, body: body)
            }
        }
        // A timer, not a task group: a group would still wait for the upload (FLU-113).
        let timer = Task {
            try await Task.sleep(for: .seconds(seconds))
            task.cancel()
        }
        defer { timer.cancel() }
        do {
            return try await task.value
        } catch {
            if task.isCancelled { throw CloudError.timedOut }
            throw error as? CloudError ?? CloudError.network
        }
    }

    private static func post(_ request: URLRequest, body: Data) async throws -> Data {
        let (data, response) = try await session.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        Log.speech.info("meeting cloud · HTTP \(status, privacy: .public)")
        try CloudResponse.check(status)
        return data
    }
}
