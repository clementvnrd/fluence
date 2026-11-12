import CryptoKit
import FluenceCore
import FluenceDictionary
import Foundation

/// FLU-132: in Précis mode, a finished meeting is transcribed by ElevenLabs (Scribe v3) before
/// the final pass: the call's channel with its voices told apart, the mic as the user's. The
/// spools are decrypted in memory and uploaded from memory; nothing plaintext reaches the disk.
/// Any failure — no key, a refusal, the network, the deadline, an odd answer — gives nil, and
/// the Mac's own pass (local diarization of the live transcript) runs as before. A quit during
/// the upload leaves the recording marker: the next launch's recovery tries again, then falls
/// back the same way. Logs carry counts, sizes, timings and HTTP statuses only.
enum MeetingCloud {
    struct Request: Sendable {
        let key: String
        let terms: [String]
    }

    struct Transcript: Sendable {
        var microphone: [TranscriptSegment]
        var system: [TranscriptSegment]
        /// The provider's voices on the call's channel.
        var turns: [SpeakerTurn]
    }

    /// Nil in Privé, and in Précis without a readable key (a fallback, recorded).
    @MainActor static func request() -> Request? {
        guard let provider = Settings.shared.cloudProvider else { return nil }
        guard let key = try? CloudKeys.shared.key(for: provider) else {
            Log.speech.error("meeting cloud · no key: the Mac transcribes the meeting")
            Diagnostics.recovery("meeting.cloud.fallback", CloudError.noKey)
            return nil
        }
        return Request(key: key, terms: DictionaryStore.shared.biasPhrases)
    }

    /// Every channel with a spool, or nil when any of them fails. A channel without a spool
    /// keeps its live segments.
    static func transcribe(
        _ request: Request,
        microphone: URL?,
        system: URL?,
        key: SymmetricKey,
        live: [TranscriptSegment],
        corrector: DictionaryCorrector
    ) async -> Transcript? {
        guard microphone != nil || system != nil else { return nil }
        var transcript = Transcript(
            microphone: live.filter { $0.source == .microphone },
            system: live.filter { $0.source == .system },
            turns: []
        )
        do {
            // The call first: when it fails, the mic is not sent for nothing.
            if let system {
                (transcript.system, transcript.turns) = try await channel(
                    system, source: .system, request, key: key, corrector: corrector, live: transcript.system
                )
            }
            if let microphone {
                (transcript.microphone, _) = try await channel(
                    microphone, source: .microphone, request, key: key, corrector: corrector, live: transcript.microphone
                )
            }
            Log.speech.info("""
                meeting cloud · \(transcript.system.count, privacy: .public) call segments, \
                \(Set(transcript.turns.map(\.speaker)).count, privacy: .public) voices, \
                \(transcript.microphone.count, privacy: .public) mic segments
                """)
            return transcript
        } catch {
            let kind = (error as? CloudError)?.kind ?? "spool unreadable"
            Log.speech.error("meeting cloud · \(kind, privacy: .public): the Mac transcribes the meeting")
            Diagnostics.recovery("meeting.cloud.fallback", error)
            return nil
        }
    }

    private static func channel(
        _ url: URL,
        source: AudioSource,
        _ request: Request,
        key: SymmetricKey,
        corrector: DictionaryCorrector,
        live: [TranscriptSegment]
    ) async throws -> (segments: [TranscriptSegment], turns: [SpeakerTurn]) {
        let reader = try MeetingAudioSpoolReader(url: url, key: key)
        // ElevenLabs refuses under 100 ms of audio.
        guard reader.sampleCount >= MeetingAudioFormat.sampleRate / 10 else { return (live, []) }
        let seconds = Double(reader.sampleCount) / Double(MeetingAudioFormat.sampleRate)
        let (urlRequest, body) = CloudRequest.meeting(
            key: request.key, pcm: pcm(reader), diarize: source == .system, terms: request.terms
        )
        let deadline = CloudFallback.meetingDeadline(audioSeconds: seconds)
        let started = ContinuousClock.now

        func attempt() async throws -> Data {
            let (status, data) = try await send(urlRequest, body: body, within: deadline)
            try CloudResponse.check(status)
            return data
        }
        let data: Data
        do {
            data = try await attempt()
        } catch let error as CloudError where error.isTransient {
            try await Task.sleep(for: .seconds(10))
            data = try await attempt()
        }

        guard let words = CloudTranscript.words(json: data) else { throw CloudError.malformed }
        // The provider heard nothing where the Mac heard words: keep the Mac's.
        if words.isEmpty, live.contains(where: { !$0.text.isEmpty }) { throw CloudError.malformed }
        let elapsed = (ContinuousClock.now - started).components.seconds
        Log.speech.info("""
            meeting cloud · \(source.rawValue, privacy: .public) · \(Int(seconds), privacy: .public)s audio, \
            \(body.count / 1_000_000, privacy: .public) MB, \(elapsed, privacy: .public)s · \(words.count, privacy: .public) words
            """)
        return CloudTranscript.channel(
            words, source: source, speakerID: source == .system ? Speaker.othersID : Speaker.meID,
            transform: { corrector.apply(to: $0).text }
        )
    }

    /// The spool's samples as 16-bit PCM, decrypted in memory a minute at a time.
    private static func pcm(_ reader: MeetingAudioSpoolReader) -> Data {
        var data = Data(capacity: reader.sampleCount * 2)
        let step = MeetingAudioFormat.sampleRate * 60
        var offset = 0
        while offset < reader.sampleCount {
            let count = min(step, reader.sampleCount - offset)
            // The spool's own Int16 values back (it stores `Int16(x · Int16.max)`).
            let samples = reader.samples(from: offset, count: count).map { Int16(($0 * Float(Int16.max)).rounded()).littleEndian }
            samples.withUnsafeBytes { data.append(contentsOf: $0) }
            offset += count
        }
        return data
    }

    /// Ephemeral: no cache, cookie or credential reaches the disk. The wait is bounded by each
    /// channel's deadline in `send`; the session's own limits only stop a link that hangs.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        // A long file is uploaded, then worked on with nothing coming back for a while.
        configuration.timeoutIntervalForRequest = 1800
        configuration.timeoutIntervalForResource = 1800
        return URLSession(configuration: configuration)
    }()

    private static func send(_ request: URLRequest, body: Data, within seconds: Double) async throws -> (status: Int, body: Data) {
        let task = Task { () async throws -> (status: Int, body: Data) in
            let (data, response) = try await session.upload(for: request, from: body)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        // A timer, not a task group: a group would still wait for the upload (FLU-113).
        let timer = Task {
            try await Task.sleep(for: .seconds(seconds))
            task.cancel()
        }
        defer { timer.cancel() }
        do {
            let answer = try await task.value
            Log.speech.info("meeting cloud · HTTP \(answer.status, privacy: .public)")
            return answer
        } catch {
            throw task.isCancelled ? CloudError.timedOut : CloudError.network
        }
    }
}
