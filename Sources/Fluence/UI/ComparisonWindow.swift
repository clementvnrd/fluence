import SwiftUI

/// The comparison window replaced a generated HTML file opened in the browser. That approach
/// needed a `file://` URL, spawned a fresh tab on every open, left stale tabs showing old data
/// — and kept a second plaintext copy of every transcript on disk. A window owned by the app
/// has none of those problems: one instance, always live, nothing to refresh.
struct ComparisonWindow: View {
    @Bindable var controller: DictationController
    @State private var store = RunStore.shared
    @State private var settings = Settings.shared
    @State private var isConfirmingClear = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.roomy) {
                header
                recordBar

                if store.runs.isEmpty {
                    emptyState
                } else {
                    ForEach(Array(store.comparisons.enumerated()), id: \.offset) { _, group in
                        ComparisonCard(runs: group)
                    }
                    ForEach(Array(store.singles.enumerated()), id: \.offset) { _, run in
                        SingleCard(run: run)
                    }
                }
            }
            .padding(DS.Space.wide)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: DS.Window.comparisonMinimum.width, minHeight: DS.Window.comparisonMinimum.height)
        .background(DS.Color.panel)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text("Engine comparison")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                Silkscreen(text: "\(store.runs.count) recording\(store.runs.count == 1 ? "" : "s")")
            }
            Spacer()
            if !store.runs.isEmpty {
                TransportKey(title: "Clear") { isConfirmingClear = true }
            }
        }
        // Clear wipes every transcript, not just the comparisons shown here, and there's no
        // undo — so it asks, as "Delete all" in the main window does.
        .confirmationDialog(
            "Delete all \(store.runs.count) recordings?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { RunLog.clear() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes your whole transcription history. It can't be undone.")
        }
    }

    /// One button that records every engine at once — no hotkeys, and the results appear in
    /// this same window, so there's nowhere to go afterwards to read them.
    private var recordBar: some View {
        let isRecording = controller.state.isActive

        // The same transport key and record lamp as the main window: red here means what it
        // means everywhere else — the mic is open.
        return VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.base) {
                TransportKey(
                    title: isRecording ? "Stop" : "Record all three",
                    systemImage: isRecording ? "stop.fill" : "circle.fill",
                    isEngaged: isRecording
                ) {
                    if isRecording {
                        controller.stopButtonRecording()
                    } else {
                        controller.startButtonRecording()
                    }
                }
                Lamp(color: DS.Color.record, isLit: isRecording)
            }

            Text(statusLine(isRecording: isRecording))
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
        }
        .padding(.bottom, DS.Space.tight)
    }

    private func statusLine(isRecording: Bool) -> String {
        if isRecording { return "Recording — click Stop when you're done talking." }
        if !controller.transcript.isEmpty { return controller.transcript }
        return WisprReader.isInstalled
            ? "Click Record, talk, click Stop. Apple, Parakeet and Wispr Flow all hear it."
            : "Click Record, talk, click Stop. Wispr Flow isn't installed, so it's Apple vs Parakeet."
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.snug) {
            Image(systemName: "waveform")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.inkSecondary)
            Text("Hold \(settings.pushToTalkKey.displayName), say a sentence, let go.")
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            Text(settings.compareMode
                 ? "Both engines run on that one recording and appear here."
                 : "Turn on Compare mode in the menu bar to see both engines at once.")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.panel)
    }
}

private struct ComparisonCard: View {
    let runs: [DictationRun]

    /// Fastest first. The engines are *measured* sequentially, so arrival order reflects
    /// which ran first, not which is quicker — sorting by measured time is what makes the
    /// winner readable at a glance.
    private var ranked: [DictationRun] {
        runs.sorted { $0.processSeconds < $1.processSeconds }
    }

    /// How much faster the winner was, once both are in.
    private var margin: String? {
        guard runs.count > 1,
              let best = ranked.first,
              let worst = ranked.last,
              best.processSeconds > 0
        else { return nil }
        let ratio = worst.processSeconds / best.processSeconds
        let delta = worst.processSeconds - best.processSeconds
        guard delta > 0.005 else { return "tied" }
        return String(format: "%@ %.1f× faster · %.2fs ahead", best.engine, ratio, delta)
    }

    /// Case and punctuation are normalized away: Apple auto-punctuates and Parakeet
    /// doesn't, and that's a formatting difference, not a recognition error.
    ///
    /// Said in words, not colors: green and amber belong to the meters.
    private var verdict: String {
        if Set(runs.map(\.text)).count == 1 { return "identical" }
        let normalized = Set(runs.map {
            $0.text.lowercased().split { !$0.isLetter && !$0.isNumber }.joined(separator: " ")
        })
        return normalized.count == 1 ? "same words" : "words differ"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack {
                Text(runs.first.map { "\($0.date.formatted(date: .omitted, time: .standard)) · held \($0.audioSeconds, format: .number.precision(.fractionLength(1)))s" } ?? "")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                Spacer()
                Silkscreen(text: verdict, color: DS.Color.ink)
                    .padding(.horizontal, DS.Space.snug)
                    .padding(.vertical, DS.Space.hair)
                    .background(DS.Color.selection, in: .rect(cornerRadius: DS.Radius.chip))

                // Deletes the whole group: every engine here transcribed one utterance, so
                // removing that utterance means removing all of its rows together.
                if let group = runs.first?.group {
                    Button {
                        withAnimation { RunLog.deleteGroup(group) }
                    } label: {
                        Image(systemName: "trash")
                            .font(DS.Font.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .help("Delete this comparison")
                }
            }
            if let margin {
                HStack(spacing: DS.Space.tight) {
                    Image(systemName: margin == "tied" ? "equal.circle.fill" : "bolt.fill")
                    Text(margin)
                }
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            } else if runs.count == 1 {
                HStack(spacing: DS.Space.tight) {
                    ProgressView().controlSize(.small)
                    Text("running second engine…")
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            }

            Divider()
            ForEach(Array(ranked.enumerated()), id: \.offset) { index, run in
                EngineRow(run: run, rank: index + 1, showRank: runs.count > 1)
            }
        }
        .padding(DS.Space.roomy)
        .background(DS.Color.cap, in: .rect(cornerRadius: DS.Radius.panel))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.panel)
                .strokeBorder(DS.Color.seam.opacity(0.5), lineWidth: DS.Border.hairline)
        )
    }
}

private struct EngineRow: View {
    let run: DictationRun
    let rank: Int
    let showRank: Bool

    private var isWinner: Bool { showRank && rank == 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            HStack(alignment: .firstTextBaseline) {
                // The winner is marked by the panel lifting, the way a selection is — not by
                // a color.
                Silkscreen(text: run.engine + (isWinner ? " · fastest" : ""), color: DS.Color.ink)
                    .padding(.horizontal, DS.Space.snug)
                    .padding(.vertical, DS.Space.hair)
                    .background(isWinner ? DS.Color.selection : .clear, in: .rect(cornerRadius: DS.Radius.chip))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.chip)
                            .strokeBorder(DS.Color.selectionEdge, lineWidth: DS.Border.hairline)
                    )
                Spacer()
                Text("\(run.processSeconds, format: .number.precision(.fractionLength(2)))s")
                    .font(isWinner ? DS.Font.counterLarge : DS.Font.counter)
                    .foregroundStyle(DS.Color.ink)
            }
            Text("\(run.realtimeFactor, format: .number.precision(.fractionLength(0)))× realtime · \(run.characters) chars")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            Text(run.text.isEmpty ? "(nothing recognized)" : run.text)
                .font(DS.Font.body)
                .foregroundStyle(run.text.isEmpty ? DS.Color.inkSecondary : DS.Color.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, DS.Space.tight)
    }
}

private struct SingleCard: View {
    let run: DictationRun

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            HStack {
                Silkscreen(text: run.engine, color: DS.Color.ink)
                Spacer()
                Text("\(run.processSeconds, format: .number.precision(.fractionLength(2)))s")
                    .font(DS.Font.counter)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            Text(run.text)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.base)
        .background(DS.Color.cap, in: .rect(cornerRadius: DS.Radius.panel))
    }
}
