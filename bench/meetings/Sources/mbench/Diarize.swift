import AVFoundation
import FluidAudio
import FluenceMeetingCore
import Foundation
import MeetingBench

/// `mbench diarize`: runs FluidAudio's offline diarizer on each meeting's mix exactly as
/// `MeetingFinalizer.diarize` does, and caches its turns and voice embeddings.
///
/// The app (Sources/Fluence/Notetaker/MeetingFinalizer.swift, `diarize(_:cap:)`):
///
///     var config = OfflineDiarizerConfig.default
///     if let cap { config.clustering.maxSpeakers = cap }
///     let manager = OfflineDiarizerManager(config: config)
///     try await manager.prepareModels()
///     let result = try await manager.process(audioSource: reader, audioLoadingSeconds: 0)
///     turns = result.segments.map { SpeakerTurn(speaker: $0.speakerId, start: …, end: …) }
///     embeddings = result.speakerDatabase ?? [:]
///
/// `process(audioSource:)` is `prepare(audioSource:)` (segmentation + embeddings, which read
/// only the segmentation/embedding parts of the config) followed by `cluster(_:)`. The bench
/// prepares once and clusters with both configurations (no cap, and maxSpeakers = the true
/// count), which is the same computation; `--check-process` verifies it on the first meeting
/// by also calling `process` and comparing the turns.
enum Diarize {
    static func run(manifest: Manifest, audioDir: URL, audioSuffix: String, cacheDir: URL, modelsDir: URL, only: Set<String>?, checkProcess: Bool, force: Bool) async throws {
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let started = Date()
        let plain = OfflineDiarizerManager(config: config(cap: nil))
        try await plain.prepareModels(directory: modelsDir)
        log("models ready in \(fmt(Date().timeIntervalSince(started))) s (\(modelsDir.path))")
        var checked = !checkProcess

        for entry in manifest.meetings where only?.contains(entry.id) ?? true {
            let cached = cacheDir.appendingPathComponent("\(entry.id).json")
            if !force, FileManager.default.fileExists(atPath: cached.path) {
                log("\(entry.id): cached, skipped (--force to redo)")
                continue
            }
            let wav = audioDir.appendingPathComponent("\(entry.id).\(audioSuffix).wav")
            let samples = try loadMono16k(wav)
            let audioSeconds = Double(samples.count) / 16_000
            let source = ArrayAudioSampleSource(samples: samples)

            let t0 = Date()
            let prepared = try await retrying { try await plain.prepare(audioSource: source, audioLoadingSeconds: 0) }
            let prepareSeconds = Date().timeIntervalSince(t0)

            var runs: [String: DiarizerRun] = [:]
            for (key, cap) in [("nocap", nil), ("cap", entry.speakers)] as [(String, Int?)] {
                let manager = cap == nil ? plain : OfflineDiarizerManager(config: config(cap: cap))
                if cap != nil { try await manager.prepareModels(directory: modelsDir) }
                let t1 = Date()
                let result = try manager.cluster(prepared)
                let clusterSeconds = Date().timeIntervalSince(t1)
                let turns = turns(of: result)
                runs[key] = DiarizerRun(maxSpeakers: cap, turns: turns, embeddings: result.speakerDatabase ?? [:],
                                        clusterSeconds: clusterSeconds)

                if !checked, cap == nil {
                    let viaProcess = try await retrying { try await plain.process(audioSource: source, audioLoadingSeconds: 0) }
                    let same = self.turns(of: viaProcess) == turns
                    log("check: process() == prepare()+cluster() on \(entry.id): \(same)")
                    guard same else { throw BenchError("prepare+cluster differs from process; the cache would not be the app's output") }
                    checked = true
                }
            }

            let meeting = DiarizedMeeting(id: entry.id, audioSeconds: audioSeconds, prepareSeconds: prepareSeconds,
                                          fluidAudioVersion: "0.17.5", runs: runs)
            let data = try JSONEncoder().encode(meeting)
            try data.write(to: cacheDir.appendingPathComponent("\(entry.id).json"), options: .atomic)
            let voices = runs.mapValues { Set($0.turns.map(\.speaker)).count }
            log("""
                \(entry.id) [\(entry.split)] \(fmt(audioSeconds)) s audio: prepare \(fmt(prepareSeconds)) s, \
                cluster \(fmt(runs["nocap"]!.clusterSeconds))/\(fmt(runs["cap"]!.clusterSeconds)) s, \
                voices no cap \(voices["nocap"]!), cap=\(entry.speakers) \(voices["cap"]!)
                """)
        }
        log("diarize total \(fmt(Date().timeIntervalSince(started))) s")
    }

    /// CoreML on a busy machine can fail a GPU submission ("GPU Timeout Error"); the work is
    /// deterministic, so a retry recomputes the same thing.
    static func retrying<T>(_ work: () async throws -> T) async throws -> T {
        var attempt = 1
        while true {
            do { return try await work() } catch where attempt < 6 {
                log("attempt \(attempt) failed (\(error.localizedDescription)); retrying")
                try await Task.sleep(for: .seconds(10 * attempt))
                attempt += 1
            }
        }
    }

    /// Mirrors MeetingFinalizer.diarize line for line.
    static func config(cap: Int?) -> OfflineDiarizerConfig {
        var config = OfflineDiarizerConfig.default
        if let cap {
            config.clustering.maxSpeakers = cap
        }
        return config
    }

    static func turns(of result: DiarizationResult) -> [SpeakerTurn] {
        result.segments.map {
            SpeakerTurn(speaker: $0.speakerId, start: Double($0.startTimeSeconds), end: Double($0.endTimeSeconds))
        }
    }

    /// AMI mixes are 16 kHz mono 16-bit PCM, the app's meeting format (MeetingAudioFormat).
    static func loadMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard format.sampleRate == 16_000, format.channelCount == 1 else {
            throw BenchError("\(url.lastPathComponent): expected 16 kHz mono, got \(format.sampleRate) Hz × \(format.channelCount)")
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw BenchError("cannot allocate audio buffer")
        }
        try file.read(into: buffer)
        return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
    }
}

struct BenchError: Error, CustomStringConvertible {
    var description: String
    init(_ description: String) { self.description = description }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fmt(_ value: Double, _ digits: Int = 1) -> String {
    String(format: "%.\(digits)f", value)
}
