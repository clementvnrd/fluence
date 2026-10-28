import AppKit
import AVFoundation
import Foundation

// Entry point of `bench`: Apple's on-device SpeechTranscriber against Parakeet TDT 0.6B
// (FluidAudio, CoreML on the Neural Engine) on the same audio file. Everything runs
// locally; the only downloads are the models, once.

let usage = """
bench — speech engine benchmark: Apple SpeechTranscriber vs Parakeet (FluidAudio / CoreML)

usage:
  bench record <out.wav>
      record 16 kHz mono audio from the microphone; press Return to stop
  bench run <audio.wav> [--ref FILE] [--v2] [--int4]
      transcribe with both engines, score them and write an HTML report

options for run:
  --ref FILE   text of what was really said; adds WER and CER
  --v2         Parakeet TDT v2 instead of v3 (English only, better recall)
  --int4       4-bit encoder: lighter and faster, a bit less accurate
"""

/// What `run` was asked to do. The audio path is always the word right after the command;
/// flags may sit anywhere after it and unknown words are ignored.
struct RunOptions {
    let audioPath: String
    let referencePath: String?
    let useV2: Bool
    let useInt4: Bool

    init?(_ words: [String]) {
        guard words.count >= 2 else { return nil }
        audioPath = words[1]
        useV2 = words.contains("--v2")
        useInt4 = words.contains("--int4")
        // A trailing `--ref` with nothing after it counts as no reference.
        if let flag = words.firstIndex(of: "--ref"), flag + 1 < words.count {
            referencePath = words[flag + 1]
        } else {
            referencePath = nil
        }
    }
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
    exit(1)
}

func machineDescription() -> String {
    var size = 0
    var chip = "Mac"
    if sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 {
        var bytes = [CChar](repeating: 0, count: size)
        if sysctlbyname("machdep.cpu.brand_string", &bytes, &size, nil, 0) == 0 {
            chip = String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
    }
    let info = ProcessInfo.processInfo
    let gigabytes = info.physicalMemory / (1 << 30)
    return "\(chip) · \(info.processorCount) cores · \(gigabytes) GB"
}

/// Pads on the right without ever cutting a longer name.
func padded(_ text: String, to width: Int) -> String {
    text.count >= width ? text : text + String(repeating: " ", count: width - text.count)
}

func summaryLines(for result: EngineResult) -> [String] {
    let name = padded(result.engine, to: 28)
    let seconds = String(format: "%6.2f", result.processSeconds)
    let speed = String(format: "%5.0f", result.realtimeFactor)
    var line = "\(name)  \(seconds)s  \(speed)× realtime"
    if let wer = result.wer {
        line += "  WER \(String(format: "%.1f", wer * 100))%"
    }
    let preview = result.text.count > 160 ? String(result.text.prefix(160)) + "…" : result.text
    return [line, "    " + preview, ""]
}

func runBenchmark(_ options: RunOptions) async throws {
    let audio = URL(fileURLWithPath: options.audioPath)
    guard FileManager.default.fileExists(atPath: audio.path) else {
        throw BenchFailure("no such file: \(options.audioPath)")
    }

    var reference: String?
    if let path = options.referencePath {
        reference = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Length taken from the file as stored, before any conversion.
    let probe = try AVAudioFile(forReading: audio)
    let audioSeconds = Double(probe.length) / probe.fileFormat.sampleRate
    print("audio: \(audio.lastPathComponent) (\(String(format: "%.1f", audioSeconds))s)")
    print("")

    // One engine at a time, Apple first; that order is kept in every output.
    print("▸ Apple SpeechTranscriber…")
    let apple = try await AppleEngine.transcribe(audio, audioSeconds: audioSeconds)
    print("▸ Parakeet via FluidAudio… (the first run downloads the CoreML models once)")
    let parakeet = try await ParakeetEngine.transcribe(
        audio, audioSeconds: audioSeconds, useV2: options.useV2, useInt4: options.useInt4
    )
    var results = [apple, parakeet]

    // Scored only now that both engines are done, so a scoring bug cannot pass for an
    // engine failure.
    if let reference {
        for index in results.indices {
            results[index].wer = Scoring.wordErrorRate(reference: reference, hypothesis: results[index].text)
            results[index].cer = Scoring.characterErrorRate(reference: reference, hypothesis: results[index].text)
        }
    }

    print("")
    for result in results {
        for line in summaryLines(for: result) { print(line) }
    }

    // Reports land in the current directory, named after the audio file, replacing any
    // previous ones.
    let stem = audio.deletingPathExtension().lastPathComponent
    let here = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let jsonURL = here.appendingPathComponent("\(stem)-results.json")
    let htmlURL = here.appendingPathComponent("\(stem)-dashboard.html")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(results).write(to: jsonURL)

    let page = Dashboard.html(.init(
        audioName: audio.lastPathComponent,
        audioSeconds: audioSeconds,
        machine: machineDescription(),
        results: results,
        reference: reference
    ))
    try Data(page.utf8).write(to: htmlURL)

    print("wrote \(jsonURL.lastPathComponent) and \(htmlURL.lastPathComponent)")
    NSWorkspace.shared.open(htmlURL)
}

let words = Array(CommandLine.arguments.dropFirst())

do {
    switch words.first {
    case "record":
        guard words.count >= 2 else { throw BenchFailure("usage: bench record <out.wav>") }
        try await MicRecorder.record(to: URL(fileURLWithPath: words[1]))
    case "run":
        guard let options = RunOptions(words) else { throw BenchFailure("usage: bench run <audio.wav>") }
        try await runBenchmark(options)
    default:
        // No command or an unknown one: show the help and leave quietly.
        print(usage)
    }
} catch {
    fail(error)
}
exit(0)
