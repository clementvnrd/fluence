import CryptoKit
import FluidAudio
import Foundation
import FluenceDictionary

extension MeetingAudioSpoolReader: AudioSampleSource {}

/// The pass after a meeting ends: who said what.
///
/// 1. Diarize the **system channel only** with FluidAudio's `OfflineDiarizerManager`
///    (pyannote segmentation + WeSpeaker + VBx), reading the encrypted spool directly. The
///    mic is the user by construction, so their voice can never be split into clusters.
///    Calendar attendees give a speaker-count ceiling.
/// 1b. Consolidate the voices (`SpeakerConsolidation`, FLU-22): merge near-duplicates,
///    absorb voices heard for a few seconds, cap the count with the call's participants
///    when the window's list looks complete (FLU-33) or the calendar's.
/// 2. Attribute each system word to the voice most active over it, split segments where
///    the voice changes, relabel `S1…Sn` by first appearance (`SpeakerAssignment`).
/// 3. Merge with the mic transcript, dropping mic echoes (`TranscriptMerger`).
/// 4. Name the voices: meeting window, then voice prints (opt-in), then the calendar by
///    elimination (`SpeakerNaming`).
///
/// Without system audio (tap denied, or a mic-only call) step 1 is skipped and remote
/// speech stays "Others".
enum MeetingFinalizer {
    struct Input: Sendable {
        var meeting: Meeting
        var systemSpool: URL?
        var key: SymmetricKey?
        var corrector: DictionaryCorrector
        /// What the call window showed during the meeting: a cap only when its list looks
        /// complete (FLU-22, FLU-33).
        var windowRoster = ParticipantRoster()
    }

    struct Output: Sendable {
        var meeting: Meeting
        /// `S1…Sn` → voice embedding, for voice-print matching and enrolment.
        var voices: [String: [Float]]
    }

    /// Steps 1–3. Naming needs the voice-print store (main actor), so it is separate.
    static func attribute(_ input: Input) async -> Output {
        var meeting = input.meeting
        let mic = meeting.segments.filter { $0.source == .microphone }
        let system = meeting.segments.filter { $0.source == .system }

        var turns: [SpeakerTurn] = []
        var rawEmbeddings: [String: [Float]] = [:]
        if !system.isEmpty, let url = input.systemSpool, let key = input.key {
            do {
                let reader = try MeetingAudioSpoolReader(url: url, key: key)
                if reader.sampleCount >= 2 * MeetingAudioFormat.sampleRate {
                    let cap = SpeakerConsolidation.speakerCap(roster: input.windowRoster, attendees: meeting.attendees.count)
                    (turns, rawEmbeddings) = try await diarize(reader, ceiling: SpeakerConsolidation.diarizerCeiling(cap: cap))
                    let consolidated = SpeakerConsolidation.consolidate(turns: turns, embeddings: rawEmbeddings, cap: cap)
                    Log.speech.info("""
                        voices: \(Set(turns.map(\.speaker)).count, privacy: .public) from the diarizer, \
                        \(Set(consolidated.turns.map(\.speaker)).count, privacy: .public) after consolidation \
                        (cap \(cap.map(String.init) ?? "none", privacy: .public), \
                        window list \(input.windowRoster.isComplete ? "complete" : "not trusted", privacy: .public))
                        """)
                    turns = consolidated.turns
                    rawEmbeddings = consolidated.embeddings
                }
            } catch {
                Log.speech.error("diarization failed, remote speech stays unattributed: \(error.localizedDescription, privacy: .public)")
                Diagnostics.error("meeting.diarization", error)
            }
        }

        let attribution = SpeakerAssignment.attribute(
            system,
            turns: turns,
            fallbackID: Speaker.othersID,
            transform: { input.corrector.apply(to: $0).text }
        )
        var segments = TranscriptMerger.merge(microphone: mic, system: attribution.segments)
        for index in segments.indices { segments[index].isFinal = true }
        meeting.segments = segments

        // Speakers: me (as it was), then S1…Sn, then "Others" if anything stayed unattributed.
        let me = meeting.speakers.first(where: \.isMe) ?? .me()
        let labels = attribution.labels.values.sorted { Int($0.dropFirst()) ?? 0 < Int($1.dropFirst()) ?? 0 }
        var speakers = [me] + labels.map { meeting.speaker($0) ?? Speaker(id: $0) }
        if segments.contains(where: { $0.speakerID == Speaker.othersID }) {
            speakers.append(.others)
        }
        meeting.speakers = speakers

        var voices: [String: [Float]] = [:]
        for (raw, label) in attribution.labels {
            if let embedding = rawEmbeddings[raw] { voices[label] = embedding }
        }
        return Output(meeting: meeting, voices: voices)
    }

    /// Step 4. `window`: remote display names read from the meeting window, already cleaned
    /// (`ParticipantNames.clean`), and whether its list looked complete (FLU-33).
    @MainActor
    static func name(_ output: Output, window: ParticipantRoster) -> Meeting {
        var meeting = output.meeting
        var similarity: [String: [String: Double]] = [:]
        if NotetakerSettings.shared.voicePrintsEnabled, !meeting.attendees.isEmpty {
            similarity = VoicePrintStore.shared.similarities(for: output.voices, allowedNames: meeting.attendees)
        }
        let candidates = SpeakerNaming.Candidates(
            windowParticipants: window.names,
            windowListComplete: window.isComplete,
            attendees: meeting.attendees,
            voicePrintSimilarity: similarity
        )
        meeting.speakers = SpeakerNaming.name(meeting.speakers, candidates: candidates)
        return meeting
    }

    private static func diarize(
        _ reader: MeetingAudioSpoolReader,
        ceiling: Int?
    ) async throws -> ([SpeakerTurn], [String: [Float]]) {
        var config = OfflineDiarizerConfig.default
        if let ceiling {
            // A ceiling, not an exact count: not everyone in the call speaks.
            config.clustering.maxSpeakers = ceiling
        }
        let manager = OfflineDiarizerManager(config: config)
        try await manager.prepareModels()
        let started = Date()
        let result = try await manager.process(audioSource: reader, audioLoadingSeconds: 0)
        Log.speech.info("""
            diarized \(Double(reader.sampleCount) / Double(MeetingAudioFormat.sampleRate), format: .fixed(precision: 0))s \
            in \(Date().timeIntervalSince(started), format: .fixed(precision: 1))s
            """)
        let turns = result.segments.map {
            SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
        return (turns, result.speakerDatabase ?? [:])
    }
}
