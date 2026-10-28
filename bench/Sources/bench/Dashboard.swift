import Foundation

/// Builds `<stem>-dashboard.html`: one standalone page (inline CSS, no script, no font or
/// image fetched) so it opens from disk with no network. Every string that comes from the
/// run is escaped before it lands in the markup.
enum Dashboard {

    struct Input {
        let audioName: String
        let audioSeconds: Double
        let machine: String
        let results: [EngineResult]
        let reference: String?
    }

    static func html(_ input: Input) -> String {
        let fastest = winner(of: input.results) { $0.processSeconds }
        let mostAccurate = winner(of: input.results) { $0.wer }
        let referenceWords = input.reference.map { Scoring.words(of: Scoring.normalise($0)) }

        let cards = input.results.map { result in
            card(
                for: result,
                isFastest: result.engine == fastest,
                isMostAccurate: result.engine == mostAccurate,
                referenceWords: referenceWords
            )
        }.joined(separator: "\n")

        let subtitle = "\(escape(input.audioName)) · \(oneDecimal(input.audioSeconds))s of audio · \(escape(input.machine))"

        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Speech engine benchmark</title>
        <style>
        \(stylesheet)
        </style>
        </head>
        <body>
        <main class="page">
        <header class="masthead">
        <h1>Speech engine benchmark</h1>
        <p class="subtitle">\(subtitle)</p>
        </header>
        <section class="engines">
        \(cards)
        </section>
        \(referencePanel(input.reference))
        <footer class="notes">
        <p><strong>RTF</strong> (real-time factor) is seconds of audio transcribed per second of work: the higher, the faster.</p>
        <p>Load time is kept out of RTF: Apple's models come preloaded with macOS, whereas Parakeet has to load its own at the start of every process.</p>
        <p>WER and CER compare normalised text (lower case, punctuation removed), so punctuation an engine adds by itself is not scored as a mistake.</p>
        </footer>
        </main>
        </body>
        </html>

        """
    }

    // MARK: Pieces

    private static func card(
        for result: EngineResult, isFastest: Bool, isMostAccurate: Bool, referenceWords: [String]?
    ) -> String {
        var badges: [String] = []
        if isFastest { badges.append(#"<span class="pill win">fastest</span>"#) }
        if isMostAccurate { badges.append(#"<span class="pill win">most accurate</span>"#) }
        badges.append(#"<span class="pill info">\#(escape(result.detail))</span>"#)

        let werText = result.wer.map { "\(oneDecimal($0 * 100))%" } ?? "—"
        let cerText = result.cer.map { "\(oneDecimal($0 * 100))%" } ?? "—"

        let transcript: String
        if let referenceWords {
            let heard = Scoring.words(of: Scoring.normalise(result.text))
            transcript = Scoring.align(referenceWords: referenceWords, hypothesisWords: heard)
                .map(markup)
                .joined(separator: " ")
        } else {
            transcript = escape(result.text)
        }

        return """
        <article class="card">
        <h2>\(escape(result.engine))</h2>
        <p class="load">load \(String(format: "%.2f", result.loadSeconds))s</p>
        <div class="pills">\(badges.joined(separator: " "))</div>
        <div class="tiles">
        <div class="tile"><span class="label">Process</span><span class="figure">\(String(format: "%.2f", result.processSeconds))s</span></div>
        <div class="tile"><span class="label">RTF</span><span class="figure">\(String(format: "%.0f", result.realtimeFactor))×</span></div>
        <div class="tile"><span class="label">WER</span><span class="figure">\(werText)</span></div>
        </div>
        <div class="transcript">
        <span class="label">Transcript · CER \(cerText)</span>
        <p>\(transcript)</p>
        </div>
        </article>
        """
    }

    private static func markup(_ token: Scoring.Token) -> String {
        let word = escape(token.word)
        switch token.kind {
        case .match:
            return word
        case .substitution(let expected):
            return #"<span class="swap" title="expected: \#(escape(expected))">\#(word)</span>"#
        case .insertion:
            return #"<span class="extra" title="inserted">\#(word)</span>"#
        case .deletion:
            return #"<span class="missed" title="missed">\#(word)</span>"#
        }
    }

    private static func referencePanel(_ reference: String?) -> String {
        if let reference {
            return """
            <section class="panel">
            <h2>Reference</h2>
            <p class="reference">\(escape(reference))</p>
            </section>
            """
        }
        return """
        <section class="panel note">
        <h2>No reference transcript</h2>
        <p class="muted">Accuracy was not scored. Write down what you actually said in a text file and run again with <code>--ref &lt;file&gt;</code> to get both WER and CER.</p>
        </section>
        """
    }

    // MARK: Helpers

    /// Engine name of the result with the smallest metric; results without the metric are
    /// skipped, and on a tie the one listed first keeps the title.
    private static func winner(of results: [EngineResult], by metric: (EngineResult) -> Double?) -> String? {
        var best: (engine: String, value: Double)?
        for result in results {
            guard let value = metric(result) else { continue }
            if best == nil || value < best!.value {
                best = (result.engine, value)
            }
        }
        return best?.engine
    }

    private static func oneDecimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: Style

    // Light by default, dark when the system asks for it; `data-theme` on <html> overrides
    // either way (nothing sets it today, it is there for whoever wants to force one).
    private static let stylesheet = """
    :root {
      --canvas: #f6f6f3; --card: #ffffff; --text: #1b1c1f; --soft: #6c6f76; --rule: #e3e3de;
      --blue: #3b82f6; --violet: #8b5cf6; --ok: #16a34a; --ko: #dc2626; --caution: #d97706;
      --code: rgba(59, 130, 246, 0.10);
    }
    @media (prefers-color-scheme: dark) {
      :root:not([data-theme="light"]) {
        --canvas: #111214; --card: #1c1d21; --text: #ececee; --soft: #9a9ca3; --rule: #2d2f35;
        --blue: #60a5fa; --violet: #a78bfa; --ok: #4ade80; --ko: #f87171; --caution: #fbbf24;
        --code: rgba(96, 165, 250, 0.16);
      }
    }
    :root[data-theme="dark"] {
      --canvas: #111214; --card: #1c1d21; --text: #ececee; --soft: #9a9ca3; --rule: #2d2f35;
      --blue: #60a5fa; --violet: #a78bfa; --ok: #4ade80; --ko: #f87171; --caution: #fbbf24;
      --code: rgba(96, 165, 250, 0.16);
    }
    * { box-sizing: border-box; }
    body {
      margin: 0; background: var(--canvas); color: var(--text);
      font: 15px/1.6 ui-rounded, -apple-system, BlinkMacSystemFont, "SF Pro Rounded", "Helvetica Neue", sans-serif;
    }
    .page { max-width: 1040px; margin: 0 auto; padding: 48px 28px 64px; }
    .masthead h1 {
      margin: 0 0 6px; font-size: 40px; line-height: 1.15; letter-spacing: -0.02em;
      background: linear-gradient(90deg, var(--blue), var(--violet));
      -webkit-background-clip: text; background-clip: text; color: transparent;
    }
    .subtitle { margin: 0 0 28px; color: var(--soft); font-size: 14px; }
    .engines { display: grid; grid-template-columns: repeat(auto-fit, minmax(420px, 1fr)); gap: 20px; }
    .card, .panel {
      background: var(--card); border: 1px solid var(--rule); border-radius: 16px; padding: 22px 24px;
    }
    .panel { margin-top: 20px; }
    .card h2, .panel h2 { margin: 0; font-size: 19px; }
    .load { margin: 2px 0 12px; color: var(--soft); font-size: 13px; }
    .pills { display: flex; flex-wrap: wrap; gap: 6px; margin-bottom: 16px; }
    .pill { border-radius: 999px; padding: 2px 10px; font-size: 12px; font-weight: 600; }
    .pill.win { color: var(--ok); background: color-mix(in srgb, var(--ok) 14%, transparent); }
    .pill.info { color: var(--blue); background: color-mix(in srgb, var(--blue) 12%, transparent); font-weight: 500; }
    .tiles { display: grid; grid-template-columns: repeat(3, 1fr); gap: 10px; }
    .tile { border: 1px solid var(--rule); border-radius: 12px; padding: 10px 12px; }
    .label { display: block; color: var(--soft); font-size: 11px; letter-spacing: 0.06em; text-transform: uppercase; }
    .figure { display: block; font-size: 26px; font-weight: 700; font-variant-numeric: tabular-nums; }
    .transcript { margin-top: 16px; padding-top: 14px; border-top: 1px solid var(--rule); }
    .transcript p { margin: 6px 0 0; }
    .swap { color: var(--ko); text-decoration: underline wavy var(--ko); text-underline-offset: 3px; }
    .extra { color: var(--caution); }
    .missed { color: var(--soft); text-decoration: line-through; opacity: 0.55; }
    .reference, .muted { color: var(--soft); }
    .note h2 { font-size: 16px; }
    code { background: var(--code); border-radius: 4px; padding: 1px 5px; font-size: 13px; }
    .notes { margin-top: 28px; color: var(--soft); font-size: 12.5px; }
    .notes p { margin: 4px 0; }
    """
}
