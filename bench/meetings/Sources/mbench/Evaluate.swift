import FluenceMeetingCore
import Foundation
import MeetingBench

/// `mbench evaluate`: scores the cached diarizer output, before and after consolidation,
/// sweeps the consolidation thresholds on dev, and reports the chosen ones on test.
enum Evaluate {
    struct Loaded {
        var entry: MeetingEntry
        var meeting: DiarizedMeeting
        var reference: [Segment]
        var uem: [(Double, Double)]
    }

    struct SweepPoint: Codable {
        var mergeSimilarity: Double
        var minorSeconds: Double
        var minorShare: Double
        var noCap: PooledScore
        var cap: PooledScore
        var objective: Double { (noCap.der + cap.der) / 2 }
    }

    struct Report: Codable {
        var createdAt: String
        /// Which audio the diarizer heard: `headset` (AMI Mix-Headset as is) or `voip` (scripts/voipify.sh).
        var condition: String
        var fluidAudioVersion: String
        var collarSeconds: Double
        var baselineSettings: Settings
        var recommendedSettings: Settings
        var bestNoCapSettings: Settings
        var bestCapSettings: Settings
        /// split → variant/settings label → pooled score.
        var pooled: [String: [String: PooledScore]]
        /// split → label → per-meeting scores.
        var meetings: [String: [String: [MeetingScore]]]
        var sweep: [SweepPoint]
        var probe: Probe
        var timings: [String: Double]
    }

    struct Settings: Codable, Equatable {
        var mergeSimilarity: Double
        var minorSeconds: Double
        var minorShare: Double

        init(mergeSimilarity: Double, minorSeconds: Double, minorShare: Double) {
            self.mergeSimilarity = mergeSimilarity; self.minorSeconds = minorSeconds; self.minorShare = minorShare
        }
        init(_ s: SpeakerConsolidation.Settings) {
            mergeSimilarity = s.mergeSimilarity; minorSeconds = s.minorSeconds; minorShare = s.minorShare
        }
        var consolidation: SpeakerConsolidation.Settings {
            var s = SpeakerConsolidation.Settings()
            s.mergeSimilarity = mergeSimilarity; s.minorSeconds = minorSeconds; s.minorShare = minorShare
            return s
        }
        var label: String { "merge \(fmt(mergeSimilarity, 3)), minor min(\(fmt(minorSeconds, 0)) s, \(fmt(minorShare * 100, 1)) %)" }
    }

    /// The grid. mergeSimilarity 1.01 = never merge by similarity; minorSeconds 0 or
    /// minorShare 0 = no minor voices.
    static let mergeGrid: [Double] = (stride(from: 0.55, through: 0.8501, by: 0.025).map { ($0 * 1000).rounded() / 1000 } + [0.68, 1.01]).sorted()
    static let minorSecondsGrid: [Double] = [0, 2, 4, 8, 15, 30, 60]
    static let minorShareGrid: [Double] = [0, 0.01, 0.02, 0.03, 0.05, 0.1]

    static func run(manifest: Manifest, setupDir: URL, cacheDir: URL, resultsDir: URL, condition: String, chosen: Settings? = nil) throws {
        let started = Date()
        var loaded: [Loaded] = []
        for entry in manifest.meetings {
            let cache = cacheDir.appendingPathComponent("\(entry.id).json")
            guard let data = try? Data(contentsOf: cache) else { log("skip \(entry.id): not diarized"); continue }
            let meeting = try JSONDecoder().decode(DiarizedMeeting.self, from: data)
            let rttm = try String(contentsOf: setupDir.appendingPathComponent("only_words/rttms/\(entry.split)/\(entry.id).rttm"), encoding: .utf8)
            let uem = try String(contentsOf: setupDir.appendingPathComponent("uems/\(entry.split)/\(entry.id).uem"), encoding: .utf8)
            loaded.append(Loaded(entry: entry, meeting: meeting, reference: RTTM.parse(rttm), uem: RTTM.parseUEM(uem)))
        }
        let dev = loaded.filter { $0.entry.split == "dev" }
        let test = loaded.filter { $0.entry.split == "test" }
        log("loaded \(dev.count) dev, \(test.count) test meetings")

        func scores(_ set: [Loaded], _ variant: Variant, _ settings: SpeakerConsolidation.Settings) -> [MeetingScore] {
            set.map { m in
                Bench.score(entry: m.entry, reference: m.reference, uem: m.uem,
                            hypothesis: Bench.hypothesis(m.meeting, variant: variant, trueCount: m.entry.speakers, settings: settings))
            }
        }

        // Sweep on dev only.
        let t0 = Date()
        var sweep: [SweepPoint] = []
        for merge in mergeGrid {
            for seconds in minorSecondsGrid {
                for share in minorShareGrid {
                    var s = SpeakerConsolidation.Settings()
                    s.mergeSimilarity = merge; s.minorSeconds = seconds; s.minorShare = share
                    sweep.append(SweepPoint(mergeSimilarity: merge, minorSeconds: seconds, minorShare: share,
                                            noCap: PooledScore(scores(dev, .appNoCap, s)),
                                            cap: PooledScore(scores(dev, .appCap, s))))
                }
            }
        }
        let sweepSeconds = Date().timeIntervalSince(t0)
        let baseline = SpeakerConsolidation.Settings()
        func closeness(_ p: SweepPoint) -> Double {
            abs(p.mergeSimilarity - baseline.mergeSimilarity) * 10 + abs(p.minorSeconds - baseline.minorSeconds) / 60
                + abs(p.minorShare - baseline.minorShare) * 10
        }
        func pick(_ key: (SweepPoint) -> (Double, Double)) -> SweepPoint {
            sweep.min { a, b in
                let ka = key(a), kb = key(b)
                if abs(ka.0 - kb.0) > 1e-9 { return ka.0 < kb.0 }
                if abs(ka.1 - kb.1) > 1e-9 { return ka.1 < kb.1 }
                return closeness(a) < closeness(b)  // ties: stay near today's values
            }!
        }
        // `chosen`: settings picked across conditions (README), scored here on this one.
        let recommended = chosen.map { c in
            SweepPoint(mergeSimilarity: c.mergeSimilarity, minorSeconds: c.minorSeconds, minorShare: c.minorShare,
                       noCap: PooledScore(scores(dev, .appNoCap, c.consolidation)), cap: PooledScore(scores(dev, .appCap, c.consolidation)))
        } ?? pick { ($0.objective, $0.noCap.meanAbsoluteCountError + $0.cap.meanAbsoluteCountError) }
        let bestNoCap = pick { ($0.noCap.der, $0.noCap.meanAbsoluteCountError) }
        let bestCap = pick { ($0.cap.der, $0.cap.meanAbsoluteCountError) }
        func settings(_ p: SweepPoint) -> SpeakerConsolidation.Settings {
            var s = SpeakerConsolidation.Settings()
            s.mergeSimilarity = p.mergeSimilarity; s.minorSeconds = p.minorSeconds; s.minorShare = p.minorShare
            return s
        }

        var pooled: [String: [String: PooledScore]] = [:]
        var perMeeting: [String: [String: [MeetingScore]]] = [:]
        let rows: [(String, Variant, SpeakerConsolidation.Settings)] = [
            ("raw diarizer, no cap", .rawNoCap, baseline),
            ("baseline app, no cap", .appNoCap, baseline),
            ("recommended, no cap", .appNoCap, settings(recommended)),
            ("best-for-no-cap, no cap", .appNoCap, settings(bestNoCap)),
            ("raw diarizer, maxSpeakers = N", .rawCap, baseline),
            ("baseline app, cap = N", .appCap, baseline),
            ("recommended, cap = N", .appCap, settings(recommended)),
            ("best-for-cap, cap = N", .appCap, settings(bestCap)),
            (Variant.mainPartialWindow.rawValue, .mainPartialWindow, baseline),
            (Variant.branchPartialWindow.rawValue, .branchPartialWindow, baseline),
        ]
        for (split, set) in [("dev", dev), ("test", test), ("all", dev + test)] {
            for (label, variant, s) in rows {
                let sc = scores(set, variant, s)
                pooled[split, default: [:]][label] = PooledScore(sc)
                perMeeting[split, default: [:]][label] = sc
            }
        }

        let probe = Probe.measure(loaded.map { ($0.entry, $0.meeting, $0.reference) })

        let stamp = ISO8601DateFormatter().string(from: Date())
        let report = Report(
            createdAt: stamp, condition: condition, fluidAudioVersion: loaded.first?.meeting.fluidAudioVersion ?? "?", collarSeconds: 0.25,
            baselineSettings: Settings(baseline), recommendedSettings: Settings(settings(recommended)),
            bestNoCapSettings: Settings(settings(bestNoCap)), bestCapSettings: Settings(settings(bestCap)),
            pooled: pooled, meetings: perMeeting, sweep: sweep, probe: probe,
            timings: [
                "sweepSeconds": sweepSeconds,
                "evaluateSeconds": Date().timeIntervalSince(started),
                "diarizerPrepareSeconds": loaded.map(\.meeting.prepareSeconds).reduce(0, +),
                "diarizerClusterSeconds": loaded.flatMap { $0.meeting.runs.values.map(\.clusterSeconds) }.reduce(0, +),
                "audioSeconds": loaded.map(\.meeting.audioSeconds).reduce(0, +),
            ]
        )

        try FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: resultsDir.appendingPathComponent("results.json"), options: .atomic)
        let markdown = Markdown.render(report, loaded: loaded.map(\.entry), rows: rows.map(\.0),
                                       bestNoCap: bestNoCap, bestCap: bestCap, recommended: recommended)
        try Data(markdown.utf8).write(to: resultsDir.appendingPathComponent("results.md"), options: .atomic)
        log("wrote \(resultsDir.path)/results.{json,md}")

        print(markdown)
    }
}
