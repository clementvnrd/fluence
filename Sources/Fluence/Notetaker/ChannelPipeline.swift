import FluidAudio
import Foundation
import MurmurDictionary

/// The system channel's samples on the meeting timeline, for the mic's echo canceller.
/// A bounded ring: the mic reads within a second of the system writing.
final class ReferenceBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var ring: [Float]
    private var written = 0

    init(seconds: Double = 30) {
        ring = [Float](repeating: 0, count: Int(seconds * Double(MeetingAudioFormat.sampleRate)))
    }

    /// Timeline samples written so far.
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return written
    }

    func append(_ samples: [Float]) {
        lock.lock()
        defer { lock.unlock() }
        for sample in samples {
            ring[written % ring.count] = sample
            written += 1
        }
    }

    /// `[start, start + count)`; anything not (or no longer) in the ring reads as silence.
    func read(from start: Int, count: Int) -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        var result = [Float](repeating: 0, count: count)
        for i in 0..<count {
            let index = start + i
            guard index >= 0, index < written, index >= written - ring.count else { continue }
            result[i] = ring[index % ring.count]
        }
        return result
    }
}

/// One channel of a meeting, from captured blocks to transcript segments:
///
/// ```
/// host-timed blocks ─► timeline aligner ─► encrypted spool
///                              │
///          (mic, on speakers) LocalVQE with the system channel as reference
///                              │
///                   Silero VAD, one probability per 4096-sample hop
///                              │
///                   UtteranceSegmenter (≤ 14.5 s, cut at pauses)
///                              │
///                   Parakeet per utterance ─► words on the meeting clock
///                              │
///                   DictionaryCorrector ─► TranscriptSegment (mic = me, system = S?)
/// ```
///
/// Sample *i* of every stage is meeting time *i / 16 000*: the aligner pads gaps and trims
/// overlaps, the echo canceller's output is sample-aligned with its input, so utterance
/// positions are meeting times without any bookkeeping.
actor ChannelPipeline {
    struct Callbacks: Sendable {
        /// A finished live segment.
        var segment: @Sendable (TranscriptSegment) -> Void
        /// Speech was heard on this channel at this meeting time (seconds).
        var speech: @Sendable (AudioSource, TimeInterval) -> Void
    }

    static let hop = 4_096
    static let rate = Double(MeetingAudioFormat.sampleRate)

    let source: AudioSource
    private let meetingStart: UInt64
    private let callbacks: Callbacks
    private let corrector: DictionaryCorrector
    private let spool: MeetingAudioSpool?
    /// Written by the system channel, read by the mic channel.
    private let reference: ReferenceBuffer?
    /// Whether a system channel exists to cancel against (mic only).
    private let hasSystemChannel: Bool

    private var aligner = TimelineAligner()
    private var spoolFailed = false

    // Echo stage (mic only).
    private var rawBlock: [Float] = []
    private var rawPosition = 0
    private var echoStream: LocalVqeStream?
    private var echoUnavailable = false
    private var echoActive = false
    private var blocksSinceRouteCheck = Int.max
    private var outputIsHeadphones = true

    // VAD and segmentation.
    private var pendingHop: [Float] = []
    private var history = SampleHistory(seconds: 30)
    private var vadState = VadStreamState.initial()
    private var vadFailed = false
    private var segmenter = UtteranceSegmenter()
    private var transcriptions: [Task<Void, Never>] = []

    init(
        source: AudioSource,
        meetingStart: UInt64,
        spool: MeetingAudioSpool?,
        reference: ReferenceBuffer?,
        hasSystemChannel: Bool,
        corrector: DictionaryCorrector,
        callbacks: Callbacks
    ) {
        self.source = source
        self.meetingStart = meetingStart
        self.spool = spool
        self.reference = reference
        self.hasSystemChannel = hasSystemChannel
        self.corrector = corrector
        self.callbacks = callbacks
    }

    // MARK: - Input

    func consume(_ audio: CapturedAudio) async {
        let time = MeetingAudioFormat.seconds(from: meetingStart, to: audio.hostTime)
        let placement = aligner.place(time: time, count: audio.samples.count)
        var samples = [Float](repeating: 0, count: placement.padding)
        samples += audio.samples.dropFirst(placement.dropLeading)
        guard !samples.isEmpty else { return }
        await accept(samples)
    }

    /// Flushes everything still buffered, transcribes the last utterance, waits for every
    /// transcription in flight and closes the spool.
    func finish() async {
        if source == .microphone, !rawBlock.isEmpty {
            rawBlock += [Float](repeating: 0, count: Self.hop - rawBlock.count)
            await runEchoStage()
        }
        if echoActive, let echoStream {
            if let tail = try? await echoStream.flush() { await analyse(tail) }
            echoActive = false
        }
        if !pendingHop.isEmpty {
            await analyse([Float](repeating: 0, count: Self.hop - pendingHop.count))
        }
        for utterance in segmenter.finish() {
            startTranscription(utterance)
        }
        for task in transcriptions { await task.value }
        transcriptions.removeAll()
        do {
            try spool?.close()
        } catch {
            Log.audio.error("spool close failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func accept(_ samples: [Float]) async {
        if let spool, !spoolFailed {
            do {
                try spool.append(samples)
            } catch {
                spoolFailed = true
                Log.audio.error("spool write failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        switch source {
        case .system:
            reference?.append(samples)
            await analyse(samples)
        case .microphone:
            var remaining = samples[...]
            while !remaining.isEmpty {
                let take = min(Self.hop - rawBlock.count, remaining.count)
                rawBlock += remaining.prefix(take)
                remaining = remaining.dropFirst(take)
                if rawBlock.count == Self.hop { await runEchoStage() }
            }
        }
    }

    // MARK: - Echo cancellation (mic)

    /// One 4096-sample block of mic audio through LocalVQE, or straight through when the
    /// user hears the call on headphones, there is no system channel, or the model is
    /// unavailable.
    private func runEchoStage() async {
        let block = rawBlock
        let position = rawPosition
        rawBlock.removeAll(keepingCapacity: true)
        rawPosition += block.count

        blocksSinceRouteCheck += 1
        if blocksSinceRouteCheck >= 8 {  // ~2 s
            blocksSinceRouteCheck = 0
            outputIsHeadphones = CoreAudioObjects.outputIsHeadphones
        }
        let wantEcho = hasSystemChannel && !outputIsHeadphones && !echoUnavailable

        if wantEcho, echoStream == nil {
            do {
                echoStream = try await MeetingSpeechModels.shared.echoCanceller().makeStream()
            } catch {
                echoUnavailable = true
                Log.audio.error("echo canceller unavailable, text dedupe only: \(error.localizedDescription, privacy: .public)")
            }
        }

        guard wantEcho, let echoStream else {
            if echoActive, let echoStream {
                // Leaving echo cancellation: drain its delay line first, so output stays
                // sample-aligned with input.
                echoActive = false
                if let tail = try? await echoStream.flush() { await analyse(tail) }
            }
            await analyse(block)
            return
        }

        if !echoActive {
            echoActive = true
            try? await echoStream.reset()
            Log.audio.info("echo cancellation on (speakers)")
        }

        // The system channel usually runs a little ahead; wait briefly for its block.
        if let reference {
            for _ in 0..<15 where reference.count < position + block.count {
                try? await Task.sleep(for: .milliseconds(20))
            }
        }
        let far = reference?.read(from: position, count: block.count) ?? [Float](repeating: 0, count: block.count)
        do {
            let clean = try await echoStream.enhance(mic: block, reference: far)
            await analyse(clean)
        } catch {
            // A failed call discards the stream's clip; restart cleanly and keep the
            // timeline intact with the unprocessed block.
            Log.audio.error("echo cancellation failed: \(error.localizedDescription, privacy: .public)")
            echoActive = false
            await analyse(block)
        }
    }

    // MARK: - VAD and utterances

    private func analyse(_ samples: [Float]) async {
        var remaining = samples[...]
        while !remaining.isEmpty {
            let take = min(Self.hop - pendingHop.count, remaining.count)
            pendingHop += remaining.prefix(take)
            remaining = remaining.dropFirst(take)
            guard pendingHop.count == Self.hop else { continue }

            let hop = pendingHop
            pendingHop.removeAll(keepingCapacity: true)
            history.append(hop)
            let probability = await speechProbability(hop)
            if probability >= segmenter.config.threshold {
                callbacks.speech(source, Double(history.count) / Self.rate)
            }
            for utterance in segmenter.push(probability) {
                startTranscription(utterance)
            }
        }
    }

    private func speechProbability(_ hop: [Float]) async -> Float {
        if !vadFailed {
            do {
                let vad = try await MeetingSpeechModels.shared.vadManager()
                let result = try await vad.processStreamingChunk(hop, state: vadState)
                vadState = result.state
                return result.probability
            } catch {
                vadFailed = true
                Log.speech.error("VAD unavailable, falling back to energy: \(error.localizedDescription, privacy: .public)")
            }
        }
        // Fallback: a crude energy gate (about −40 dBFS).
        let energy = hop.reduce(0) { $0 + $1 * $1 } / Float(hop.count)
        return energy.squareRoot() > 0.01 ? 0.9 : 0.1
    }

    private func startTranscription(_ utterance: Utterance) {
        let samples = history.samples(from: utterance.startSample, to: utterance.endSample)
        guard !samples.isEmpty else { return }
        transcriptions.removeAll { $0.isCancelled }
        transcriptions.append(Task { await self.transcribe(samples, startSample: utterance.startSample) })
    }

    private func transcribe(_ samples: [Float], startSample: Int) async {
        let start = Double(startSample) / Self.rate
        let end = start + Double(samples.count) / Self.rate
        // Parakeet refuses less than 0.3 s; trailing silence does not move the timings.
        var audio = samples
        if audio.count < 8_000 { audio += [Float](repeating: 0, count: 8_000 - audio.count) }

        do {
            let manager = try await ParakeetModels.shared.manager()
            var decoderState = try TdtDecoderState()
            let result = try await manager.transcribe(audio, decoderState: &decoderState, language: nil)
            let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            let tokens = (result.tokenTimings ?? []).map {
                TimedToken(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence)
            }
            let words = WordBuilder.words(from: tokens, offset: start)
            let segment = TranscriptSegment(
                source: source,
                speakerID: source == .microphone ? Speaker.meID : Speaker.othersID,
                start: words.first.map { min($0.start, end) } ?? start,
                end: words.last.map { min(max($0.end, start), end) } ?? end,
                text: corrector.apply(to: text).text,
                words: words
            )
            callbacks.segment(segment)
        } catch {
            Log.speech.error("meeting utterance not transcribed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The last few seconds of a channel's analysed samples, addressed by timeline position.
struct SampleHistory {
    private var ring: [Float]
    /// Samples appended so far (the timeline position of the next one).
    private(set) var count = 0

    init(seconds: Double) {
        ring = [Float](repeating: 0, count: Int(seconds * Double(MeetingAudioFormat.sampleRate)))
    }

    mutating func append(_ samples: [Float]) {
        for sample in samples {
            ring[count % ring.count] = sample
            count += 1
        }
    }

    /// `[start, end)`, clamped to what is still held.
    func samples(from start: Int, to end: Int) -> [Float] {
        let lower = max(start, count - ring.count, 0)
        let upper = min(end, count)
        guard upper > lower else { return [] }
        return (lower..<upper).map { ring[$0 % ring.count] }
    }
}
