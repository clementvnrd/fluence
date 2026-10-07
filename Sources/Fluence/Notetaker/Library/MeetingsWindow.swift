import FluenceNotesCore
import SwiftUI

/// The meetings library: every recorded meeting, newest first, searchable, with its notes
/// and transcript.
///
/// Laid out like the main window: a card across the top, then the list in a card on the
/// left and the selected meeting on the right — its own card of facts and keys, a row of
/// section keys, and a card holding the section.
struct MeetingsWindow: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        ZStack {
            DS.Color.chassis.ignoresSafeArea()

            VStack(spacing: DS.Space.base) {
                LibraryHeader(model: model)

                if let message = model.bannerMessage {
                    ProblemBanner(
                        message: message,
                        // The store's own error clears only when the store can be read again.
                        onDismiss: model.store.lastError == nil ? { model.dismissProblem() } : nil
                    )
                }

                HStack(alignment: .top, spacing: DS.Space.base) {
                    LibraryCard {
                        MeetingList(model: model)
                    }
                    .frame(width: DS.Library.listWidth)

                    if model.meeting != nil {
                        MeetingDetail(model: model)
                    } else {
                        LibraryCard {
                            EmptyPanel(
                                label: model.store.summaries.isEmpty ? "Aucune réunion pour l'instant" : "Aucune réunion sélectionnée",
                                detail: model.store.summaries.isEmpty
                                    ? "Les réunions apparaissent ici une fois que Fluence a pris des notes."
                                    : "Choisissez-en une dans la liste."
                            )
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .padding(DS.Space.roomy)
        }
        .frame(minWidth: DS.Library.minWidth, minHeight: DS.Library.minHeight)
        .onAppear {
            if model.selectedID == nil { model.selectedID = model.visible.first?.id }
        }
    }
}

/// The owner's card: a white rounded surface with a hairline border, content clipped to it.
private struct LibraryCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .fill(DS.Color.panel)
            )
            .clipShape(RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.panel, style: .continuous)
                    .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
            )
    }
}

/// French names of the notes templates, for this window only: `NotesTemplate.title` lives in
/// FluenceNotesCore and is left as it is.
fileprivate extension NotesTemplate {
    var libraryTitle: String {
        switch self {
        case .general: "Général"
        case .oneOnOne: "1:1"
        case .clientCall: "Appel client"
        case .standUp: "Stand-up"
        }
    }
}

// MARK: - Header

private struct LibraryHeader: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        HStack(spacing: DS.Space.roomy) {
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text("Réunions")
                    .font(DS.Font.title)
                    .foregroundStyle(DS.Color.ink)
                Text("Notes conservées sur ce Mac uniquement")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }

            LabeledFact(label: "Nombre") {
                DeckWindow {
                    Readout(text: "\(model.store.summaries.count)")
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.tight)
                }
            }

            Spacer()

            LibraryHeaderAccessories(model: model)
        }
        .padding(DS.Space.roomy)
        .background(BrushedPanel())
    }
}

// MARK: - List

private struct MeetingList: View {
    @Bindable var model: MeetingLibraryModel

    /// "3 réunions" or, while searching, "2 trouvées" (French: singular for 0 and 1).
    private var footerText: String {
        guard model.searchHits != nil else {
            let count = model.store.summaries.count
            return "\(count) réunion" + (count > 1 ? "s" : "")
        }
        let count = model.visible.count
        return "\(count) trouvée" + (count > 1 ? "s" : "")
    }

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $model.query, placeholder: "Rechercher parmi les réunions…")

            if model.visible.isEmpty {
                EmptyPanel(
                    label: model.store.summaries.isEmpty ? "Aucune réunion" : "Aucun résultat",
                    detail: model.store.summaries.isEmpty
                        ? "Rien n'a encore été enregistré."
                        : "La recherche porte sur les titres, les noms, les notes et les transcriptions."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.tight) {
                        ForEach(model.visible) { summary in
                            MeetingRow(
                                summary: summary,
                                isSelected: model.selectedID == summary.id,
                                isWriting: model.generator.isBusy(summary.id)
                            ) {
                                model.select(summary.id)
                            }
                        }
                    }
                    .padding(DS.Space.snug)
                }
            }

            HStack {
                Text(footerText)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                Spacer()
            }
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.snug)
            .background(DS.Color.well)
            .overlay(alignment: .top) {
                Rectangle().fill(DS.Color.seam).frame(height: DS.Border.seam)
            }
        }
    }
}

private struct MeetingRow: View {
    let summary: MeetingSummary
    let isSelected: Bool
    let isWriting: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.snug) {
                    Text(summary.title.isEmpty ? "Réunion sans titre" : summary.title)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.tight)
                    // Lit: notes written. The lamp is the same instrument as the dictionary's
                    // "enabled" lamp.
                    Lamp(color: DS.Color.meterGreen, isLit: summary.hasNotes, size: DS.Library.lampSmall)
                        .help(summary.hasNotes ? "Notes rédigées" : (isWriting ? "Rédaction des notes…" : "Pas de notes"))
                }
                HStack(spacing: DS.Space.snug) {
                    Text(summary.startedAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                    Readout(text: DurationText.format(summary.duration))
                        .foregroundStyle(DS.Color.inkSecondary)
                }
                if !summary.speakerNames.isEmpty {
                    Text(summary.speakerNames.joined(separator: ", "))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                        .lineLimit(1)
                }
                if isWriting {
                    Silkscreen(text: "Rédaction des notes", color: DS.Color.accent)
                }
            }
            .padding(DS.Space.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                    .fill(isSelected ? DS.Color.selection : DS.Color.panel)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                            .strokeBorder(
                                isSelected ? DS.Color.selectionEdge : DS.Color.seam,
                                lineWidth: isSelected ? DS.Border.bevel : DS.Border.hairline
                            )
                    )
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Detail

private struct MeetingDetail: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        if let meeting = model.meeting {
            VStack(spacing: DS.Space.base) {
                DetailHeader(model: model, meeting: meeting)

                HStack(spacing: DS.Space.snug) {
                    SelectorKeys(
                        options: MeetingLibraryModel.Tab.allCases,
                        title: \.title,
                        selection: model.tab
                    ) { tab in
                        withAnimation(DS.Motion.panel) { model.tab = tab }
                    }
                    Spacer()
                }

                LibraryCard {
                    Group {
                        switch model.tab {
                        case .recap: RecapSection(model: model, meeting: meeting)
                        case .nextSteps: NextStepsSection(model: model, meeting: meeting)
                        case .decisions: DecisionsSection(model: model, meeting: meeting)
                        case .transcript: TranscriptSection(model: model, meeting: meeting)
                        case .myNotes: MyNotesSection(model: model)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .sheet(item: $model.renaming) { _ in
                RenameSpeakerSheet(model: model)
            }
            .confirmationDialog(
                "Supprimer « \(meeting.title) » ?",
                isPresented: $model.isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Supprimer la réunion", role: .destructive) { model.deleteSelected() }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("Sa transcription, ses notes et l'audio éventuellement conservé sont effacés avec leur clé de chiffrement. "
                    + "Cette action est irréversible.")
            }
            .confirmationDialog(
                "Remplacer ces notes ?",
                isPresented: $model.isConfirmingRegenerate,
                titleVisibility: .visible
            ) {
                Button("Régénérer les notes") { model.regenerate() }
                Button("Annuler", role: .cancel) {}
            } message: {
                Text("De nouvelles notes sont rédigées à partir de la transcription avec le modèle de notes "
                    + "« \(model.template.libraryTitle) » et remplacent les actuelles dès qu'elles sont prêtes. "
                    + "En cas d'échec, les notes actuelles sont conservées.")
            }
        }
    }
}

private struct DetailHeader: View {
    @Bindable var model: MeetingLibraryModel
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.snug) {
                if model.isEditingTitle {
                    TextField("Titre", text: $model.titleDraft)
                        .textFieldStyle(.plain)
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Color.ink)
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.tight)
                        .background(DS.Color.well, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                        .onSubmit { model.commitTitle() }
                        .onExitCommand { model.isEditingTitle = false }
                    TransportKey(title: "Enregistrer", isEngaged: true) { model.commitTitle() }
                } else {
                    Text(meeting.title.isEmpty ? "Réunion sans titre" : meeting.title)
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Color.ink)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Button { model.beginEditingTitle() } label: {
                        Silkscreen(text: "Modifier le titre", color: DS.Color.accent)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }

            HStack(alignment: .top, spacing: DS.Space.wide) {
                LabeledFact(label: "Date") {
                    Text(meeting.startedAt, format: .dateTime.weekday(.abbreviated).day().month(.wide).year().hour().minute())
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.ink)
                }
                LabeledFact(label: "Durée") {
                    DeckWindow {
                        Readout(text: DurationText.format(meeting.duration))
                            .padding(.horizontal, DS.Space.snug)
                            .padding(.vertical, DS.Space.hair)
                    }
                }
                LabeledFact(label: "Participants") {
                    Text(meeting.participantNames.joined(separator: ", "))
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.ink)
                        .lineLimit(2)
                }
                Spacer()
            }

            HStack(alignment: .bottom, spacing: DS.Space.base) {
                LabeledFact(label: "Modèle de notes") {
                    SelectorKeys(
                        options: NotesTemplate.allCases,
                        title: \.libraryTitle,
                        selection: model.template
                    ) { model.setTemplate($0) }
                }
                Spacer()
                TransportKey(
                    title: meeting.notes == nil ? "Rédiger les notes" : "Régénérer les notes",
                    systemImage: "text.badge.star",
                    isEnabled: !model.generator.isBusy(meeting.id)
                ) {
                    model.requestRegenerate()
                }
                .help(meeting.notes == nil
                    ? "Rédiger les notes avec le modèle local"
                    : "Rédiger de nouvelles notes à partir de la transcription ; elles remplacent les actuelles")
            }

            HStack(spacing: DS.Space.snug) {
                MeetingExportKeys(model: model, meeting: meeting)
                Spacer()
                TransportKey(title: "Supprimer", systemImage: "trash") {
                    model.isConfirmingDelete = true
                }
                .help("Supprimer cette réunion")
            }
        }
        .padding(DS.Space.roomy)
        .background(BrushedPanel())
    }
}

// MARK: - Notes sections

/// Shown in place of the notes while there are none: writing, failed, or not written.
private struct NotesStatusPanel: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            switch model.status {
            case .queued:
                statusLine(lit: true, label: "Notes en attente", detail: "Les notes d'une autre réunion sont en cours de rédaction.")
            case .working(let progress):
                statusLine(lit: true, label: "Rédaction des notes", detail: Self.describe(progress))
            case .failed(let message):
                statusLine(lit: false, label: "Pas de notes", detail: message)
                DeckKey(title: "Réessayer", systemImage: "arrow.clockwise") { model.regenerate() }
            case nil:
                statusLine(
                    lit: false,
                    label: "Pas de notes",
                    detail: FoundationModelFormatter.unavailableReason.map { "Les notes nécessitent le modèle local : \($0)" }
                        ?? "Les notes de cette réunion n'ont pas encore été rédigées. La transcription est complète."
                )
                DeckKey(title: "Rédiger les notes", systemImage: "text.badge.star") { model.regenerate() }
            }
        }
        .padding(DS.Space.roomy)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusLine(lit: Bool, label: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.snug) {
            Lamp(color: DS.Color.meterGreen, isLit: lit, size: DS.Library.lampSmall)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - DS.Library.lampBaselineNudge }
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Text(label)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.ink)
                Text(detail)
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func describe(_ progress: NotesProgress) -> String {
        switch progress {
        case .preparing: "Préparation de la transcription…"
        case .reading(let index, let count): "Lecture de la partie \(index) sur \(count)…"
        case .merging: "Assemblage de ce que dit chaque partie…"
        case .writing: "Rédaction des notes finales…"
        }
    }
}

/// While a regeneration runs, existing notes stay on screen with a status line above.
private struct RegeneratingLine: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        if case .working(let progress) = model.status {
            line("Réécriture des notes — " + NotesStatusPanel.describe(progress))
        } else if case .queued = model.status {
            line("Réécriture des notes — en attente")
        } else if case .failed(let message) = model.status {
            line(message)
        }
    }

    private func line(_ text: String) -> some View {
        Silkscreen(text: text, color: DS.Color.inkSecondary)
            .padding(.horizontal, DS.Space.roomy)
            .padding(.top, DS.Space.base)
    }
}

/// Scrolling card content with the notes' provenance at the bottom.
private struct NotesPage<Content: View>: View {
    @Bindable var model: MeetingLibraryModel
    let notes: MeetingNotes
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.roomy) {
                content
                Text("Rédigé sur ce Mac par \(notes.model), le \(notes.generatedAt.formatted(date: .abbreviated, time: .shortened)).")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            .padding(DS.Space.roomy)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            RegeneratingLine(model: model)
        }
    }
}

private struct RecapSection: View {
    @Bindable var model: MeetingLibraryModel
    let meeting: Meeting

    var body: some View {
        if let notes = meeting.notes {
            NotesPage(model: model, notes: notes) {
                Text(notes.recap)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else {
            NotesStatusPanel(model: model)
        }
    }
}

private struct NextStepsSection: View {
    @Bindable var model: MeetingLibraryModel
    let meeting: Meeting

    var body: some View {
        if let notes = meeting.notes {
            NotesPage(model: model, notes: notes) {
                if notes.nextSteps.isEmpty {
                    Silkscreen(text: "Aucune prochaine étape", color: DS.Color.inkSecondary)
                }
                ForEach(Array(notes.nextSteps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.snug) {
                        Image(systemName: "square")
                            .font(.system(size: DS.Library.glyphLarge, weight: .regular))
                            .foregroundStyle(DS.Color.inkSecondary)
                        VStack(alignment: .leading, spacing: DS.Space.hair) {
                            Text(step.text)
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Color.ink)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: DS.Space.snug) {
                                if let owner = step.owner {
                                    Silkscreen(text: owner, color: DS.Color.inkSecondary)
                                }
                                if let due = step.due {
                                    Silkscreen(text: "Échéance : " + due, color: DS.Color.inkSecondary)
                                }
                            }
                        }
                    }
                }
            }
        } else {
            NotesStatusPanel(model: model)
        }
    }
}

private struct DecisionsSection: View {
    @Bindable var model: MeetingLibraryModel
    let meeting: Meeting

    var body: some View {
        if let notes = meeting.notes {
            NotesPage(model: model, notes: notes) {
                BulletGroup(label: "Décisions", items: notes.decisions, none: "Aucune décision enregistrée")
                BulletGroup(label: "Questions ouvertes", items: notes.openQuestions, none: "Aucune question ouverte")
            }
        } else {
            NotesStatusPanel(model: model)
        }
    }
}

private struct BulletGroup: View {
    let label: String
    let items: [String]
    let none: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            Silkscreen(text: label, color: DS.Color.inkSecondary)
            if items.isEmpty {
                Text(none)
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.snug) {
                    Text("—")
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.inkSecondary)
                    Text(item)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Transcript

private struct TranscriptSection: View {
    @Bindable var model: MeetingLibraryModel
    let meeting: Meeting

    var body: some View {
        VStack(spacing: 0) {
            speakerStrip
            if meeting.segments.isEmpty {
                EmptyPanel(label: "Pas de transcription", detail: "Rien n'a été transcrit pendant cette réunion.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.base) {
                        ForEach(meeting.segments.sorted { $0.start < $1.start }) { segment in
                            row(segment)
                        }
                    }
                    .padding(DS.Space.roomy)
                }
            }
        }
    }

    /// Every speaker with where their name came from; click one to rename it.
    private var speakerStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Space.snug) {
                Silkscreen(text: "Intervenants", color: DS.Color.inkSecondary)
                ForEach(meeting.speakers) { speaker in
                    Button { model.beginRenaming(speaker) } label: {
                        HStack(spacing: DS.Space.tight) {
                            Text(speaker.displayName)
                                .font(DS.Font.label)
                                .foregroundStyle(DS.Color.ink)
                            Silkscreen(text: Self.source(speaker), color: DS.Color.inkSecondary)
                        }
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.tight)
                        .background(DS.Color.cap, in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                        )
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .help("Renommer \(speaker.displayName) partout dans cette réunion")
                }
            }
            .padding(.horizontal, DS.Space.roomy)
            .padding(.vertical, DS.Space.snug)
        }
        .background(DS.Color.well)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Color.seam).frame(height: DS.Border.seam)
        }
    }

    private func row(_ segment: TranscriptSegment) -> some View {
        let speaker = meeting.speaker(segment.speakerID) ?? Speaker(id: segment.speakerID)
        return HStack(alignment: .firstTextBaseline, spacing: DS.Space.base) {
            Text(Clock.format(segment.start))
                .font(DS.Font.counter)
                .foregroundStyle(DS.Color.inkSecondary)
                .frame(width: DS.Library.timestampWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Button { model.beginRenaming(speaker) } label: {
                    Text(speaker.displayName)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                }
                .buttonStyle(.plain)
                .help("Renommer \(speaker.displayName) partout dans cette réunion")
                Text(segment.text)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink.opacity(segment.isFinal ? 1 : DS.Library.inkDim))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func source(_ speaker: Speaker) -> String {
        switch speaker.nameSource {
        case .user: "nommé par vous"
        case .meetingWindow: "depuis l'appel"
        case .voicePrint: "empreinte vocale"
        case .calendar: "calendrier"
        case nil: speaker.isMe ? "micro" : "sans nom"
        }
    }
}

private struct RenameSpeakerSheet: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            Text("Renommer l'intervenant")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
            Text("Le nouveau nom s'applique à chaque réplique de cet intervenant dans cette réunion, "
                + "ainsi qu'à ses prochaines étapes. Laissez le champ vide pour revenir à un intervenant numéroté.")
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Silkscreen(text: "Nom")
                TextField(model.renaming?.displayName ?? "Nom", text: $model.renameDraft)
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink)
                    .padding(DS.Space.snug)
                    .background(DS.Color.well, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                            .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                    )
                    .onSubmit { model.commitRename() }
            }
            HStack(spacing: DS.Space.snug) {
                Spacer()
                TransportKey(title: "Annuler") { model.renaming = nil }
                TransportKey(title: "Renommer", isEngaged: true) { model.commitRename() }
            }
        }
        .padding(DS.Space.panel)
        .frame(width: DS.Library.sheetWidth)
        .background(BrushedPanel(radius: DS.Radius.window))
    }
}

// MARK: - My notes

private struct MyNotesSection: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $model.notesDraft)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .scrollContentBackground(.hidden)
                .padding(DS.Space.base)
                .frame(minHeight: DS.Library.editorMinHeight)

            HStack(spacing: DS.Space.snug) {
                Silkscreen(
                    text: "Ce que vous avez saisi pendant la réunion — les notes le considèrent comme le plus important",
                    color: DS.Color.inkSecondary
                )
                Spacer()
                DeckKey(title: model.hasUnsavedNotes ? "Enregistrer" : "Enregistré", isEnabled: model.hasUnsavedNotes) {
                    model.saveUserNotes()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.snug)
            .overlay(alignment: .top) {
                Rectangle().fill(DS.Color.seam).frame(height: DS.Border.seam)
            }
        }
    }
}
