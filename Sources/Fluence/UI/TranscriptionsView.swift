import AppKit
import FluenceCore
import MurmurDictionary
import SwiftUI

/// Transcriptions (mock-up 02): every dictation, newest first, by day.
///
/// No "Toutes les apps" filter: a dictation does not record which app it went to, and the
/// list does not invent it.
struct TranscriptionsView: View {
    @Bindable var controller: DictationController
    @State private var store = RunStore.shared
    @State private var settings = Settings.shared
    @State private var query = ""
    @State private var isConfirmingClear = false

    private var runs: [DictationRun] {
        let all = Array(store.runs.reversed())
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return all }
        return all.filter { $0.text.localizedStandardContains(trimmed) || ($0.rawText ?? "").localizedStandardContains(trimmed) }
    }

    private var subtitle: String {
        var text = FrenchFormat.count(store.runs.count, "enregistrement")
            + " · maintenez \(ShortcutLabel.display(settings.pushToTalkKey.shortName)) pour dicter"
        if settings.lastTranscriptShortcuts { text += ", ⌃⌘V recolle la dernière" }
        return text
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                ContentTitle(title: "Transcriptions", subtitle: subtitle)
                    .layoutPriority(1)  // the controls shrink first (FLU-18)
                Spacer(minLength: DS.Space.roomy)
                DictationHeaderControls(controller: controller)
            }
            .padding(.horizontal, DS.Space.panel)
            .padding(.top, 28)
            .padding(.bottom, DS.Space.roomy)

            SearchWell(text: $query, placeholder: "Rechercher parmi les transcriptions…")
                .padding(.horizontal, DS.Space.panel)
                .padding(.bottom, DS.Space.base)

            // History couldn't be read or saved (the Keychain refused the key): persistent,
            // because the failure persists.
            if let problem = store.problem {
                ProblemBanner(message: problem)
                    .padding(.horizontal, DS.Space.panel)
                    .padding(.bottom, DS.Space.base)
            }

            if runs.isEmpty {
                EmptyState(
                    systemImage: store.runs.isEmpty ? "waveform" : "magnifyingglass",
                    title: store.runs.isEmpty ? "Aucune dictée pour l'instant" : "Aucun résultat",
                    detail: store.runs.isEmpty
                        ? "Maintenez \(ShortcutLabel.display(settings.pushToTalkKey.shortName)) dans n'importe quelle app, parlez, relâchez : le texte s'écrit là où est le curseur."
                        : "La recherche porte sur le texte écrit et sur ce qui a été entendu."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        let now = Date()
                        ForEach(FrenchDates.groupByDay(runs, date: \.date, now: now, calendar: FrenchDates.calendar)) { group in
                            DayHeader(text: FrenchDates.label(group.key, now: now, calendar: FrenchDates.calendar))
                                .padding(.top, group.key == .today ? 0 : 8)
                            ForEach(group.items) { run in
                                TranscriptionCard(run: run) {
                                    withAnimation(DS.Motion.panel) { RunLog.delete(run) }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.panel)
                    .padding(.top, 4)
                    .padding(.bottom, DS.Space.roomy)
                }
            }

            ListFooter(text: FrenchFormat.count(store.runs.count, "enregistrement")) {
                Button { isConfirmingClear = true } label: {
                    Text("Tout effacer").font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
                }
                .buttonStyle(.plain)
                .disabled(store.runs.isEmpty)
            }
        }
        .confirmationDialog(
            "Supprimer l'ensemble des \(store.runs.count) enregistrements ?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Tout supprimer", role: .destructive) { RunLog.clear() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Cette action est irréversible.")
        }
    }
}

// MARK: - Card

private struct TranscriptionCard: View {
    let run: DictationRun
    let onDelete: () -> Void

    @State private var didCopy = false
    @State private var isHovering = false
    @State private var isShowingCorrection = false
    /// What the engine heard before cleanup, when cleanup changed it.
    @State private var showsRaw = false

    private var shownText: String { showsRaw ? run.rawText ?? run.text : run.text }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                AccentChip(text: run.engine)
                Text(FrenchFormat.seconds(run.processSeconds))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(DS.Color.inkSecondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(DS.Color.well, in: Capsule())
                    .help("Temps entre le relâchement de la touche et le texte prêt")
                Spacer()
                Text(FrenchDates.time(run.date, calendar: FrenchDates.calendar))
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)

                ChipButton(title: "Corriger", systemImage: "brain", accent: true) { isShowingCorrection = true }
                    .help("Corriger cette dictée pour que Fluence apprenne")
                    .sheet(isPresented: $isShowingCorrection) {
                        CorrectionQuickSheet(initialText: run.text)
                    }

                if run.rawText != nil {
                    ChipButton(title: showsRaw ? "Nettoyé" : "Brut", accent: showsRaw) { showsRaw.toggle() }
                        .help(showsRaw ? "Afficher le texte nettoyé" : "Afficher ce qui a été entendu, avant le nettoyage")
                }

                ChipButton(
                    title: didCopy ? "Copié !" : "Copier",
                    systemImage: didCopy ? "checkmark" : "doc.on.doc",
                    tint: didCopy ? DS.Color.meterGreen : nil
                ) {
                    // Asked for, so an ordinary copy — but this Mac only: Universal Clipboard
                    // would hand the dictation to every device on the account.
                    let pasteboard = NSPasteboard.general
                    pasteboard.prepareForNewContents(with: .currentHostOnly)
                    pasteboard.setString(shownText, forType: .string)
                    didCopy = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.4))
                        didCopy = false
                    }
                }

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(DS.Color.inkSecondary)
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isHovering ? 0.8 : 0.25)
                .help("Supprimer cet enregistrement")
            }

            Text(shownText)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .textSelection(.enabled)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            if let corrections = run.corrections, !corrections.isEmpty {
                CorrectionPills(corrections: corrections)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isHovering ? DS.Color.hover : DS.Color.panel)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline))
                .shadow(
                    color: isHovering ? DS.Shadow.panel.color : DS.Shadow.raised.color,
                    radius: isHovering ? DS.Shadow.panel.radius : DS.Shadow.raised.radius,
                    x: 0,
                    y: isHovering ? DS.Shadow.panel.y : DS.Shadow.raised.y
                )
        )
        .onHover { isHovering = $0 }
    }
}

private struct CorrectionPills: View {
    let corrections: [AppliedCorrection]

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(DS.Color.meterAmber)
            ForEach(corrections, id: \.self) { correction in
                HStack(spacing: 4) {
                    Text(correction.from).strikethrough().foregroundStyle(DS.Color.inkSecondary)
                    Image(systemName: "arrow.right").font(.system(size: 7)).foregroundStyle(DS.Color.inkSecondary)
                    Text(correction.to).foregroundStyle(DS.Color.ink)
                    if correction.count > 1 {
                        Text("×\(correction.count)").font(.system(size: 9)).foregroundStyle(DS.Color.inkSecondary)
                    }
                }
                .font(.system(size: 10))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(DS.Color.meterAmber.opacity(0.10), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            Spacer()
        }
        .help("Corrections du dictionnaire appliquées à cette dictée")
    }
}
