import Foundation
import MeetingBench

// mbench diarize  <meetings.json> <audioDir> <cacheDir> [--models DIR] [--audio Mix-Headset|Array1-01] [--only ID,ID] [--check-process] [--force]
// mbench evaluate <meetings.json> <AMI-diarization-setup dir> <cacheDir> <resultsDir> [--condition headset|voip|array] [--settings MERGE,SECONDS,SHARE]
//
// Audio, caches and results live outside the repo (README.md); nothing here logs words or names.

let args = Array(CommandLine.arguments.dropFirst())
func option(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }

let usage = """
    usage: mbench diarize <meetings.json> <audioDir> <cacheDir> [--models DIR] [--audio Mix-Headset|Array1-01] [--only ID,ID] [--check-process] [--force]
           mbench evaluate <meetings.json> <setupDir> <cacheDir> <resultsDir> [--condition headset|voip|array] [--settings MERGE,SECONDS,SHARE]
    """
guard args.count >= 4 else { log(usage); exit(2) }
let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url(args[1])))

switch args[0] {
case "diarize":
    let models = url(option("--models") ?? "~/Library/Caches/FluenceBench/models")
    let only = option("--only").map { Set($0.split(separator: ",").map(String.init)) }
    try await Diarize.run(manifest: manifest, audioDir: url(args[2]), audioSuffix: option("--audio") ?? "Mix-Headset", cacheDir: url(args[3]), modelsDir: models,
                          only: only, checkProcess: args.contains("--check-process"), force: args.contains("--force"))
case "evaluate":
    guard args.count >= 5 else { log(usage); exit(2) }
    // --settings 0.7,8,0.03 reports those as "recommended" instead of this condition's own best.
    let chosen = option("--settings").map { $0.split(separator: ",").compactMap { Double($0) } }
    if let chosen, chosen.count != 3 { log(usage); exit(2) }
    try Evaluate.run(manifest: manifest, setupDir: url(args[2]), cacheDir: url(args[3]), resultsDir: url(args[4]),
                     condition: option("--condition") ?? "headset",
                     chosen: chosen.map { Evaluate.Settings(mergeSimilarity: $0[0], minorSeconds: $0[1], minorShare: $0[2]) })
default:
    log(usage)
    exit(2)
}
