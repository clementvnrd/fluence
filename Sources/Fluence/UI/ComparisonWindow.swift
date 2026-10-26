import FluenceCore
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
    /// Read from disk when the window appears and after the download it offers.
    @State private var parakeetOnDisk = ParakeetModels.isDownloaded
    @State private var parakeetDownload: DownloadState = .idle

    private enum DownloadState: Equatable { case idle, running, failed }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.roomy) {
                header
                recordBar
                if store.runs.isEmpty {
                    emptyState
                } else {
                    // Groups first (one utterance, several engines), then the lone runs.
                    ForEach(Array(store.comparisons.enumerated()), id: \.offset) { _, group in
                        ComparisonCard(
                            runs: group,
                            isRunning: group.first?.group == controller.runningComparisonGroup,
                            isWaitingForWispr: group.first?.group.map(controller.groupsWaitingForWispr.contains) ?? false
                        )
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
        .onAppear { parakeetOnDisk = ParakeetModels.isDownloaded }
    }

    /// The engines the next comparison runs: only those already on disk (FLU-48).
    private var comparedEngines: [ComparedEngine] {
        ComparisonPlan.engines(
            parakeetOnDisk: parakeetOnDisk,
            whisperOnDisk: WhisperModels.isDownloaded(variant: settings.whisperModel)
        )
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
                    title: isRecording ? "Arrêter" : "Enregistrer",
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

            if !parakeetOnDisk {
                parakeetOffer
            }
        }
        .padding(.bottom, DS.Space.tight)
    }

    private func statusLine(isRecording: Bool) -> String {
        if isRecording { return "Enregistrement en cours — cliquez sur Arrêter quand vous avez fini de parler." }
        if !controller.transcript.isEmpty { return controller.transcript }
        let names = FrenchFormat.list(comparedEngines.map(\.displayName))
        #if !FLUENCE_WITHOUT_WISPR
        // Wispr Flow hears only what this button records: Fluence's shortcut doesn't press its key.
        if WisprReader.isInstalled { return "Comparés : \(names) · Wispr Flow avec ce bouton" }
        #endif
        return "Comparés : \(names)"
    }

    /// Parakeet is compared only once its model is on disk; the download (~600 MB) is the
    /// user's click, never a side effect of a recording (FLU-48).
    private var parakeetOffer: some View {
        HStack(spacing: DS.Space.snug) {
            Text(parakeetDownload == .failed ? "Échec du téléchargement de Parakeet." : "Parakeet n'est pas téléchargé.")
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
            TransportKey(
                title: parakeetDownload == .running ? "Téléchargement…" : "Télécharger (~600 Mo)",
                systemImage: "arrow.down.circle",
                isEnabled: parakeetDownload != .running
            ) {
                downloadParakeet()
            }
        }
    }

    private func downloadParakeet() {
        guard parakeetDownload != .running else { return }
        parakeetDownload = .running
        Task {
            do {
                _ = try await ParakeetModels.shared.manager()
                parakeetDownload = .idle
            } catch {
                Log.speech.error("compare: Parakeet download failed: \(error.localizedDescription, privacy: .public)")
                Diagnostics.error("compare.parakeet.download", error)
                parakeetDownload = .failed
            }
            parakeetOnDisk = ParakeetModels.isDownloaded
        }
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
                 ? "Chaque moteur traite ce même enregistrement et s'affiche ici."
                 : "Activez le mode comparaison dans la barre des menus pour voir les moteurs côte à côte.")
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
    /// Its local engines are still running.
    let isRunning: Bool
    /// Its row from Wispr Flow is still expected.
    let isWaitingForWispr: Bool

    /// Local engines ranked by compute time; Wispr Flow's end-to-end latency, network
    /// included, apart (FLU-48, AGENTS.md: not one ranking).
    private var ranking: ComparisonRanking {
        ComparisonRanking(runs.map(\.comparisonRow))
    }

    var body: some View {
        let ranking = self.ranking
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack {
                Text(runs.first.map { "\($0.date.formatted(date: .omitted, time: .standard)) · \(FrenchFormat.seconds($0.audioSeconds, fractionDigits: 1)) d'audio" } ?? "")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                Spacer()
                // Said in words, not colors: green and amber belong to the meters.
                if let verdict = ranking.verdict {
                    Silkscreen(text: verdict.rawValue, color: DS.Color.ink)
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.hair)
                        .background(DS.Color.selection, in: .rect(cornerRadius: DS.Radius.chip))
                }

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
                    .accessibilityLabel("Supprimer cette comparaison")
                }
            }
            if let margin = ranking.marginLabel {
                HStack(spacing: DS.Space.tight) {
                    Image(systemName: ranking.margin == .tied ? "equal.circle.fill" : "bolt.fill")
                    Text(margin)
                }
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            }
            if isRunning {
                pending("autres moteurs en cours…")
            }
            #if !FLUENCE_WITHOUT_WISPR
            if isWaitingForWispr {
                pending("Wispr Flow en cours…")
            }
            #endif

            Divider()
            ForEach(Array(ranking.local.enumerated()), id: \.offset) { index, row in
                EngineRow(row: row, isWinner: index == 0 && ranking.winner != nil)
            }
            if !ranking.endToEnd.isEmpty {
                Divider()
                ForEach(Array(ranking.endToEnd.enumerated()), id: \.offset) { _, row in
                    EngineRow(row: row, isWinner: false)
                }
            }
        }
        .padding(DS.Space.roomy)
        .background(BrushedPanel())
    }

    private func pending(_ label: String) -> some View {
        HStack(spacing: DS.Space.tight) {
            ProgressView().controlSize(.small)
            Text(label)
        }
        .font(DS.Font.caption)
        .foregroundStyle(DS.Color.inkSecondary)
    }
}

private struct EngineRow: View {
    let row: ComparisonRow
    let isWinner: Bool

    private var details: String {
        guard row.status != .failed else { return row.speedLabel }
        return [row.speedLabel, FrenchFormat.count(row.text.count, "caractère")]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            HStack(alignment: .firstTextBaseline) {
                // The winner is marked by the panel lifting, the way a selection is — not by
                // a color.
                Silkscreen(text: row.engine + (isWinner ? " · le plus rapide" : ""), color: DS.Color.ink)
                    .padding(.horizontal, DS.Space.snug)
                    .padding(.vertical, DS.Space.hair)
                    .background(isWinner ? DS.Color.selection : .clear, in: .rect(cornerRadius: DS.Radius.chip))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                            .strokeBorder(DS.Color.selectionEdge, lineWidth: DS.Border.hairline)
                    )
                Spacer()
                // A failed engine has no time worth showing: its zero once read as a record.
                if row.status != .failed {
                    Text(FrenchFormat.seconds(row.seconds))
                        .font(isWinner ? DS.Font.counterLarge : DS.Font.counter)
                        .foregroundStyle(DS.Color.ink)
                }
            }
            Text(details)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
            Text(row.displayText)
                .font(DS.Font.body)
                .foregroundStyle(row.status == .transcribed ? DS.Color.ink : DS.Color.inkSecondary)
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
