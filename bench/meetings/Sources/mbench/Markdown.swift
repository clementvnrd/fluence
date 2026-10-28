import Foundation
import MeetingBench

enum Markdown {
    static func pct(_ v: Double) -> String { fmt(v * 100, 1) }
    static func signed(_ v: Double) -> String { (v > 0 ? "+" : "") + fmt(v, 2) }

    static func render(_ r: Evaluate.Report, loaded: [MeetingEntry], rows: [String],
                       bestNoCap: Evaluate.SweepPoint, bestCap: Evaluate.SweepPoint,
                       recommended: Evaluate.SweepPoint) -> String {
        var out = "# Meeting speaker bench (FLU-33) — \(r.condition) — \(r.createdAt)\n\n"
        out += "FluidAudio \(r.fluidAudioVersion) offline diarizer (app config) + FluenceMeetingCore SpeakerConsolidation. "
        let audio = ["voip": "AMI Mix-Headset, VoIP-like copy (scripts/voipify.sh)", "array": "AMI Array1-01, one far-field room microphone"]
        out += "\(audio[r.condition] ?? "AMI Mix-Headset as published"), only_words reference, DER with ±\(fmt(r.collarSeconds, 2)) s collar, overlap scored, Hungarian mapping.\n\n"
        out += "- Baseline settings: \(r.baselineSettings.label)\n"
        out += "- Recommended (min mean dev DER of no cap and cap = N, or `--settings`): \(r.recommendedSettings.label)\n"
        out += "- Best on dev, no cap only: \(r.bestNoCapSettings.label) (dev DER \(pct(bestNoCap.noCap.der)) %)\n"
        out += "- Best on dev, cap = N only: \(r.bestCapSettings.label) (dev DER \(pct(bestCap.cap.der)) %)\n\n"

        for split in ["dev", "test", "all"] {
            guard let pooled = r.pooled[split] else { continue }
            out += "## Pooled, \(split) (\(pooled.values.first?.meetings ?? 0) meetings)\n\n"
            out += "| Pipeline | DER % | Miss % | FA % | Conf % | DER no collar % | mean abs count err | mean signed | exact count |\n"
            out += "|---|---:|---:|---:|---:|---:|---:|---:|---:|\n"
            for row in rows {
                guard let p = pooled[row] else { continue }
                out += "| \(row) | \(pct(p.der)) | \(pct(p.missed)) | \(pct(p.falseAlarm)) | \(pct(p.confusion)) | \(pct(p.derNoCollar)) | \(fmt(p.meanAbsoluteCountError, 2)) | \(signed(p.meanSignedCountError)) | \(p.exactCount)/\(p.meetings) |\n"
            }
            out += "\n"
        }

        out += "## Per meeting (DER % / voices kept vs people)\n\n"
        out += "| Meeting | Split | People | " + rows.joined(separator: " | ") + " |\n"
        out += "|---|---|---:|" + rows.map { _ in "---:" }.joined(separator: "|") + "|\n"
        for entry in loaded {
            guard let split = r.meetings[entry.split] else { continue }
            var cells: [String] = []
            for row in rows {
                if let s = split[row]?.first(where: { $0.id == entry.id }) {
                    cells.append("\(pct(s.der.der)) / \(s.count.hypothesis)")
                } else { cells.append("–") }
            }
            out += "| \(entry.id) | \(entry.split) | \(entry.speakers) | " + cells.joined(separator: " | ") + " |\n"
        }

        out += "\n## Sweep on dev: best DER per mergeSimilarity (over the minor-voice grid)\n\n"
        out += "| mergeSimilarity | best no cap DER % | its minor rule | best cap DER % | its minor rule |\n|---:|---:|---|---:|---|\n"
        for merge in Evaluate.mergeGrid {
            let points = r.sweep.filter { $0.mergeSimilarity == merge }
            guard let n = points.min(by: { $0.noCap.der < $1.noCap.der }), let c = points.min(by: { $0.cap.der < $1.cap.der }) else { continue }
            out += "| \(merge > 1 ? "off" : fmt(merge, 3)) | \(pct(n.noCap.der)) | min(\(fmt(n.minorSeconds, 0)) s, \(fmt(n.minorShare * 100, 0)) %) | \(pct(c.cap.der)) | min(\(fmt(c.minorSeconds, 0)) s, \(fmt(c.minorShare * 100, 0)) %) |\n"
        }
        let base = r.sweep.first { $0.mergeSimilarity == r.baselineSettings.mergeSimilarity && $0.minorSeconds == r.baselineSettings.minorSeconds && $0.minorShare == r.baselineSettings.minorShare }
        if let base {
            out += "\nBaseline point in the grid: no cap \(pct(base.noCap.der)) %, cap \(pct(base.cap.der)) %; recommended point: no cap \(pct(recommended.noCap.der)) %, cap \(pct(recommended.cap.der)) %.\n"
        }
        let spread = r.sweep.map(\.objective)
        out += "Objective range over the whole grid: \(pct(spread.min() ?? 0)) – \(pct(spread.max() ?? 0)) %.\n"

        let p = r.probe
        out += "\n## Probe: cosine between the diarizer's raw voices (no cap), \(p.embeddingDimension)-d\n\n"
        out += "| Pairs | n | min | p10 | median | p90 | max |\n|---|---:|---:|---:|---:|---:|---:|\n"
        for (name, s) in [("same person (over-split)", p.samePerson), ("different people", p.differentPeople)] {
            func f(_ v: Double?) -> String { v.map { fmt($0, 3) } ?? "–" }
            out += "| \(name) | \(s.count) | \(f(s.min)) | \(f(s.p10)) | \(f(s.median)) | \(f(s.p90)) | \(f(s.max)) |\n"
        }
        out += "\n- different people at cosine ≥ 0.5: \(p.differentAtOrAbove050); ≥ 0.68 (would be merged today): \(p.differentAtOrAbove068)\n"
        out += "- same person at ≥ 0.68: \(p.sameAtOrAbove068)/\(p.samePerson.count); within 0.65–0.80: \(p.sameIn065to080)/\(p.samePerson.count)\n"
        out += "- any pair above 0.82: \(p.anyPairAbove082)\n"
        out += "- raw voices: \(p.rawVoices), impure (< 50 % one person): \(p.impureVoices); under 8 s: \(p.minorVoices), of which fragments of a person with a bigger voice: \(p.minorVoicesThatAreFragments)\n"
        out += "- voices per meeting [people, raw no cap, raw maxSpeakers = N]: "
        out += p.voices.keys.sorted().map { "\($0) \(p.voices[$0]!)" }.joined(separator: ", ") + "\n"

        out += "\n## Timings\n\n"
        for (k, v) in r.timings.sorted(by: { $0.key < $1.key }) { out += "- \(k): \(fmt(v)) s\n" }
        return out
    }
}
