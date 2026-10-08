import AVFoundation
import CoreML
import FluidAudio
import Foundation
import Speech
import WhisperKit

// usage: fbench <engine> <list.tsv> [modelFolder]
//   engine: whisper | parakeet-v3 | parakeet-ultra | apple
//   list.tsv: id \t wavPath  (one per line)
// prints: id \t audioSeconds \t processingSeconds \t hypothesis
let args = CommandLine.arguments
let engine = args[1]
let items: [(String, String)] = try String(contentsOfFile: args[2], encoding: .utf8)
    .split(separator: "\n").map { line in
        let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
        return (String(parts[0]), String(parts[1]))
    }

func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func load(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    let converter = AVAudioConverter(from: file.processingFormat, to: format)!
    let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024)!
    var done = false
    var error: NSError?
    converter.convert(to: out, error: &error) { _, status in
        if done { status.pointee = .endOfStream; return nil }
        done = true; status.pointee = .haveData; return buffer
    }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}

func clean(_ s: String) -> String {
    s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func emit(_ id: String, _ samples: [Float], _ elapsed: Double, _ text: String) {
    print("\(id)\t\(String(format: "%.2f", Double(samples.count) / 16_000))\t\(String(format: "%.3f", elapsed))\t\(clean(text))")
    fflush(stdout)
}

switch engine {
case "whisper":
    let kit = try await WhisperKit(WhisperKitConfig(modelFolder: args[3], verbose: false, logLevel: .none, load: true, download: false))
    // Same options as WhisperModels.transcribe in the app (FLU-20), French, no prompt.
    let options = DecodingOptions(
        verbose: false, task: .transcribe, language: "fr", temperature: 0.0,
        temperatureIncrementOnFallback: 0.2, temperatureFallbackCount: 5, usePrefillPrompt: true,
        detectLanguage: false, withoutTimestamps: true, promptTokens: nil,
        compressionRatioThreshold: 2.4, logProbThreshold: -1.0, noSpeechThreshold: 0.8,
        chunkingStrategy: .vad
    )
    _ = await kit.transcribe(audioArrays: [[Float](repeating: 0, count: 16_000)], decodeOptions: options)  // warm-up
    for (id, path) in items {
        let samples = try load(path)
        let t0 = Date()
        let results = await kit.transcribe(audioArrays: [samples], decodeOptions: options)
        let text = results.first??.compactMap { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: " ") ?? ""
        emit(id, samples, Date().timeIntervalSince(t0), text)
    }

case "parakeet-v3", "parakeet-ultra":
    let version: AsrModelVersion = engine == "parakeet-v3" ? .v3 : .ultra
    let t0 = Date()
    let models = engine == "parakeet-v3"
        ? try await AsrModels.downloadAndLoad(version: .v3, encoderPrecision: .int8)  // as in the app
        : try await AsrModels.downloadAndLoad(version: version)
    let manager = AsrManager(config: .default)
    try await manager.loadModels(models)
    err("\(engine): ready in \(Date().timeIntervalSince(t0)) s")
    for (id, path) in items {
        let samples = try load(path)
        var state = try TdtDecoderState()
        let t1 = Date()
        let result = try await manager.transcribe(samples, decoderState: &state, language: .french)
        emit(id, samples, Date().timeIntervalSince(t1), result.text)
    }

case "apple":
    let locale = Locale(identifier: "fr-FR")
    guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { err("fr-FR unsupported"); exit(1) }
    let probe = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [probe]) {
        err("apple: downloading the French asset")
        try await request.downloadAndInstall()
    }
    for (id, path) in items {
        let samples = try load(path)
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let t1 = Date()
        let collector = Task { () -> String in
            var text = ""
            for try await result in transcriber.results where result.isFinal {
                text += String(result.text.characters)
            }
            return text
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        let text = try await collector.value
        emit(id, samples, Date().timeIntervalSince(t1), text)
    }

default:
    err("unknown engine \(engine)")
    exit(2)
}
