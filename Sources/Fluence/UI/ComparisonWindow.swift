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
        .background(DS.Color.chassis)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text("Comparaison des moteurs")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                Silkscreen(text: "\(store.runs.count) enregistrement\(store.runs.count == 1 ? "" : "s")")
            }
            Spacer()
            if !store.runs.isEmpty {
                TransportKey(title: "Effacer") { isConfirmingClear = true }
            }
        }
        // Clear wipes every transcript, not just the comparisons shown here, and there's no
        // undo — so it asks, as "Delete all" in the main window does.
        .confirmationDialog(
            "Supprimer les \(store.runs.count) enregistrements ?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Tout supprimer", role: .destructive) { RunLog.clear() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cela efface tout votre historique de transcriptions. C'est irréversible.")
        }
    }

    /// Nothing to hold down here: a single key records once for every engine, and their
    /// results show up in this same window.
    private var recordBar: some View {
        let isRecording = controller.state.isActive

        // The same transport key and record lamp as the main window: red here means what it
        // means everywhere else — the mic is open.
        return VStack(alignment: .leading, spacing: DS.Space.snug) {
            HStack(spacing: DS.Space.base) {
                TransportKey(
                    title: isRecording ? "Arrêter" : "Enregistrer les trois",
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
        if isRecording { return "Enregistrement en cours — cliquez sur Arrêter quand vous avez fini de parler." }
        if !controller.transcript.isEmpty { return controller.transcript }
        #if !FLUENCE_WITHOUT_WISPR
        return WisprReader.isInstalled
            ? "Cliquez sur Enregistrer, parlez, puis sur Arrêter. Apple, Parakeet et Wispr Flow entendent tous la même chose."
            : "Cliquez sur Enregistrer, parlez, puis sur Arrêter. Wispr Flow n'est pas installé : ce sera Apple contre Parakeet."
        #else
        return "Cliquez sur Enregistrer, parlez, puis sur Arrêter. Apple et Parakeet entendent tous les deux la même chose."
        #endif
    }

    private var emptyState: some View {
        VStack(spacing: DS.Space.snug) {
            Image(systemName: "waveform")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.inkSecondary)
            Text("Maintenez \(settings.pushToTalkKey.displayName), dites une phrase, relâchez.")
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            Text(settings.compareMode
                 ? "Les deux moteurs traitent ce même enregistrement et s'affichent ici."
                 : "Activez le mode comparaison dans la barre des menus pour voir les deux moteurs à la fois.")
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

    /// The engines take turns on the same audio, so the order they arrive in only says who
    /// went first; sorting on the measured time puts the winner on top.
    private var ranked: [DictationRun] {
        runs.sorted { $0.processSeconds < $1.processSeconds }
    }

    /// Shown instead of a margin when both engines took the same time.
    private static let tied = "à égalité"

    /// How far ahead the fastest engine finished, once at least two have answered.
    private var margin: String? {
        guard ranked.count >= 2, let best = ranked.first, let slowest = ranked.last,
              best.processSeconds > 0 else { return nil }
        let ratio = slowest.processSeconds / best.processSeconds
        let delta = slowest.processSeconds - best.processSeconds
        guard delta > 0.005 else { return Self.tied }
        return String(format: "%@ : %.1f× plus rapide · %.2f s d'avance", best.engine, ratio, delta)
    }

    /// Apple punctuates and Parakeet does not, which is formatting rather than a word heard
    /// wrong, so letter case and punctuation are left out of the comparison.
    ///
    /// Said in words, not colors: green and amber belong to the meters.
    private var verdict: String {
        if Set(runs.map(\.text)).count == 1 { return "identique" }
        let normalized = Set(runs.map { run in
            run.text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).joined(separator: " ")
        })
        return normalized.count == 1 ? "mêmes mots" : "mots différents"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack {
                Text(runs.first.map { "\($0.date.formatted(date: .omitted, time: .standard)) · \($0.audioSeconds, format: .number.precision(.fractionLength(1))) s d'audio" } ?? "")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                Spacer()
                Silkscreen(text: verdict, color: DS.Color.ink)
                    .padding(.horizontal, DS.Space.snug)
                    .padding(.vertical, DS.Space.hair)
                    .background(DS.Color.selection, in: .rect(cornerRadius: DS.Radius.chip))

                // The rows of a card are one utterance seen by several engines: deleting it
                // takes every engine's version with it.
                if let group = runs.first?.group {
                    Button {
                        withAnimation(DS.Motion.panel) { RunLog.deleteGroup(group) }
                    } label: {
                        Image(systemName: "trash")
                            .font(DS.Font.caption)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .help("Supprimer cette comparaison")
                }
            }
            if let margin {
                HStack(spacing: DS.Space.tight) {
                    Image(systemName: margin == Self.tied ? "equal.circle.fill" : "bolt.fill")
                    Text(margin)
                }
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            } else if runs.count == 1 {
                HStack(spacing: DS.Space.tight) {
                    ProgressView().controlSize(.small)
                    Text("second moteur en cours…")
                }
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            }

            Divider()
            ForEach(Array(ranked.enumerated()), id: \.offset) { index, run in
                EngineRow(run: run, rank: index + 1, showRank: ranked.count > 1)
            }
        }
        .padding(DS.Space.roomy)
        .background(BrushedPanel())
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
                Silkscreen(text: run.engine + (isWinner ? " · le plus rapide" : ""), color: DS.Color.ink)
                    .padding(.horizontal, DS.Space.snug)
                    .padding(.vertical, DS.Space.hair)
                    .background(isWinner ? DS.Color.selection : .clear, in: .rect(cornerRadius: DS.Radius.chip))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                            .strokeBorder(DS.Color.selectionEdge, lineWidth: DS.Border.hairline)
                    )
                Spacer()
                Text("\(run.processSeconds, format: .number.precision(.fractionLength(2))) s")
                    .font(isWinner ? DS.Font.counterLarge : DS.Font.counter)
                    .foregroundStyle(DS.Color.ink)
            }
            Text("\(run.realtimeFactor, format: .number.precision(.fractionLength(0)))× temps réel · \(run.characters) caractères")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            Text(run.text.isEmpty ? "(rien de reconnu)" : run.text)
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
                Text("\(run.processSeconds, format: .number.precision(.fractionLength(2))) s")
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
        .background(BrushedPanel())
    }
}
