import FluenceCore
import FluenceNotesCore
import SwiftUI

// The meetings library inside the main window (FLU-12): the list (mock-up 03) and a
// meeting's page — Notes, Transcription, Mes notes (mock-ups 04 and 05).

struct MeetingsLibraryView: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        if model.isPageOpen, let meeting = model.meeting {
            MeetingPage(model: model, meeting: meeting)
        } else {
            MeetingsList(model: model)
        }
    }
}

/// French names of the notes templates: `NotesTemplate.title` lives in FluenceNotesCore.
extension NotesTemplate {
    var frenchTitle: String {
        switch self {
        case .general: "Général"
        case .oneOnOne: "1:1"
        case .clientCall: "Appel client"
        case .standUp: "Stand-up"
        }
    }
}

// MARK: - List

private struct MeetingsList: View {
    @Bindable var model: MeetingLibraryModel
    @State private var settingsModel = MeetingSettingsModel.shared
    @State private var controller = MeetingController.shared
    @State private var isConfirmingDeleteAll = false

    private var subtitle: String {
        FrenchFormat.count(model.store.summaries.count, "réunion")
    }

    private var footerText: String {
        let total = model.store.summaries.reduce(0) { $0 + $1.duration }
        let count = model.searchHits == nil && model.appFilter == nil
            ? FrenchFormat.count(model.store.summaries.count, "réunion")
            : FrenchFormat.count(model.visible.count, "trouvée")
        return total > 0 ? "\(count) · \(FrenchFormat.duration(total)) au total" : count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Réunions", subtitle: subtitle) {
                CapButton(title: "Importer", systemImage: "square.and.arrow.down") { model.importer.begin() }
                    .help("Ajouter une réunion passée depuis un fichier de transcription ou du texte collé")
                if !controller.isBusy {
                    CapButton(title: "Prendre des notes", systemImage: "plus") { controller.takeNotes() }
                        .help("Enregistrer la réunion en cours, ou tout ce que le Mac joue")
                }
            }
            .padding(.horizontal, DS.Space.panel)
            .padding(.top, 28)
            .padding(.bottom, DS.Space.roomy)

            HStack(spacing: DS.Space.snug) {
                SearchWell(text: $model.query, placeholder: "Rechercher dans les réunions…")
                let apps = model.apps
                if !apps.isEmpty {
                    MenuChip(title: model.appFilter.flatMap { id in apps.first { $0.bundleID == id }?.name } ?? "Toutes les apps") {
                        Button("Toutes les apps") { model.appFilter = nil }
                        Divider()
                        ForEach(apps, id: \.bundleID) { app in
                            Button(app.name) { model.appFilter = app.bundleID }
                        }
                    }
                }
            }
            .padding(.horizontal, DS.Space.panel)
            .padding(.bottom, DS.Space.base)

            if let message = model.bannerMessage {
                ProblemBanner(
                    message: message,
                    onDismiss: model.store.lastError == nil ? { model.dismissProblem() } : nil
                )
                .padding(.horizontal, DS.Space.panel)
                .padding(.bottom, DS.Space.base)
            }

            if model.visible.isEmpty {
                EmptyState(
                    systemImage: model.store.summaries.isEmpty ? "person.2" : "magnifyingglass",
                    title: model.store.summaries.isEmpty ? "Aucune réunion pour l'instant" : "Aucun résultat",
                    detail: model.store.summaries.isEmpty
                        ? "Quand un appel commence (Zoom, Teams, Meet…), Fluence propose de prendre des notes. Rien n'est enregistré sans vous. Vous pouvez aussi importer une ancienne transcription."
                        : "La recherche porte sur les titres, les noms, les notes et les transcriptions."
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        let now = Date()
                        ForEach(FrenchDates.groupByWeek(model.visible, date: \.startedAt, now: now, calendar: FrenchDates.calendar)) { group in
                            DayHeader(text: FrenchDates.label(group.key))
                                .padding(.top, group.key == .thisWeek ? 0 : 8)
                            ForEach(group.items) { summary in
                                MeetingRow(
                                    summary: summary,
                                    info: model.rowInfo(summary),
                                    isWriting: model.generator.isBusy(summary.id),
                                    now: now
                                ) {
                                    model.openPage(summary.id)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, DS.Space.panel)
                    .padding(.top, 4)
                    .padding(.bottom, DS.Space.roomy)
                }
            }

            ListFooter(text: footerText) {
                Button { isConfirmingDeleteAll = true } label: {
                    Text("Tout effacer").font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
                }
                .buttonStyle(.plain)
                .disabled(model.store.summaries.isEmpty)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            model.importer.open(urls)
            return !urls.isEmpty
        }
        .sheet(isPresented: Bindable(model.importer).isPresented) {
            MeetingImportSheet(importer: model.importer) { id in model.openPage(id) }
        }
        .confirmationDialog(
            "Supprimer toutes les réunions (\(model.store.summaries.count)) ?",
            isPresented: $isConfirmingDeleteAll,
            titleVisibility: .visible
        ) {
            Button("Supprimer toutes les réunions", role: .destructive) { settingsModel.deleteAllMeetings() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Chaque transcription, chaque ensemble de notes et chaque enregistrement conservé est effacé avec sa clé de chiffrement. Cette action est irréversible.")
        }
    }
}

private struct MeetingRow: View {
    let summary: MeetingSummary
    let info: MeetingLibraryModel.RowInfo
    let isWriting: Bool
    let now: Date
    let onOpen: () -> Void

    @State private var isHovering = false

    private var metaLine: String {
        var parts = [
            FrenchDates.relativeDayTime(summary.startedAt, now: now, calendar: FrenchDates.calendar),
            FrenchFormat.duration(summary.duration),
        ]
        if let app = info.appName { parts.append(app) }
        return parts.joined(separator: " · ")
    }

    private var people: [(name: String, isMe: Bool, unnamed: Bool)] {
        if !info.speakers.isEmpty {
            return info.speakers
                .filter { $0.id != Speaker.othersID }
                .map { ($0.frenchDisplayName, $0.isMe, $0.isUnnamed) }
        }
        return summary.speakerNames.map { name in
            let french = SpeakerLabel.french(displayName: name)
            return (french, name == "You", french.hasPrefix("Intervenant "))
        }
    }

    var body: some View {
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: DS.Space.base) {
                Image(systemName: info.isImported ? "doc.text" : "video")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(DS.Color.accent)
                    .frame(width: 36, height: 36)
                    .background(DS.Color.selection, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(summary.title.isEmpty ? "Réunion sans titre" : summary.title)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.ink)
                        .lineLimit(1)
                    Text(metaLine).font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary).lineLimit(1)
                    if isWriting {
                        Text("Rédaction des notes…").font(DS.Font.caption).foregroundStyle(DS.Color.accent)
                    } else if let recap = info.recapLine, !recap.isEmpty {
                        Text(recap).font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary.opacity(0.85)).lineLimit(1)
                    } else if !summary.hasNotes {
                        Text("Pas encore de notes").font(DS.Font.caption).foregroundStyle(DS.Color.silkscreen)
                    }
                }
                .layoutPriority(1)
                Spacer(minLength: DS.Space.roomy)
                VStack(alignment: .trailing, spacing: 6) {
                    AvatarStack(people: people)
                    HStack(spacing: 6) {
                        MetaChip(text: "Chiffré", systemImage: "lock.fill")
                        if info.isImported {
                            MetaChip(text: "Importée", systemImage: "square.and.arrow.down")
                        } else {
                            MetaChip(
                                text: info.keepAudio ? "Audio conservé" : "Audio non conservé",
                                systemImage: info.keepAudio ? "waveform" : "speaker.slash"
                            )
                        }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isHovering ? DS.Color.hover : DS.Color.panel)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline))
                    .shadow(color: DS.Shadow.raised.color, radius: DS.Shadow.raised.radius, y: DS.Shadow.raised.y)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}

// MARK: - Page

private struct MeetingPage: View {
    @Bindable var model: MeetingLibraryModel
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MeetingHeader(model: model, meeting: meeting)
                .padding(.horizontal, DS.Space.panel + 4)
            Rectangle().fill(DS.Color.seam).frame(height: 1).padding(.top, DS.Space.roomy)

            Group {
                switch model.tab {
                case .notes: NotesTab(model: model, meeting: meeting)
                case .transcript: TranscriptTab(model: model, meeting: meeting)
                case .myNotes: MyNotesTab(model: model)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .confirmationDialog(
            "Supprimer « \(meeting.title) » ?",
            isPresented: $model.isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Supprimer la réunion", role: .destructive) { model.deleteSelected() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Sa transcription, ses notes et l'audio éventuellement conservé sont effacés avec leur clé de chiffrement. Cette action est irréversible.")
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
                + "« \(model.template.frenchTitle) » et remplacent les actuelles dès qu'elles sont prêtes. "
                + "En cas d'échec, les notes actuelles sont conservées.")
        }
    }
}

private struct MeetingHeader: View {
    @Bindable var model: MeetingLibraryModel
    let meeting: Meeting

    private var appName: String? { meeting.appBundleID.flatMap { MeetingApps.identify($0)?.name } }

    /// "Noms repris de Zoom et de l'agenda", from where the names actually came from.
    private var namesSource: String? {
        let sources = Set(meeting.speakers.compactMap(\.nameSource))
        var parts: [String] = []
        if sources.contains(.meetingWindow) { parts.append(appName.map { "de \($0)" } ?? "de l'appel") }
        if sources.contains(.calendar) { parts.append("de l'agenda") }
        if sources.contains(.voicePrint) { parts.append("des empreintes vocales") }
        guard !parts.isEmpty else { return nil }
        return "Noms repris " + parts.joined(separator: " et ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DS.Space.snug) {
                Button { model.closePage() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text("Réunions").font(DS.Font.label)
                    }
                    .foregroundStyle(DS.Color.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut("[", modifiers: .command)
                Spacer()
                CapButton(
                    title: model.flash == "exported" ? "Exporté" : "Exporter en Markdown",
                    systemImage: "square.and.arrow.up"
                ) {
                    do {
                        if try MeetingExport.saveMarkdown(meeting) { model.showFlash("exported") }
                    } catch {
                        model.report("Le fichier Markdown n'a pas pu être écrit.")
                    }
                }
                .help("Enregistrer la réunion dans un fichier Markdown")
                CapButton(title: model.flash == "copied" ? "Copié !" : "Copier", systemImage: "doc.on.doc") {
                    MeetingExport.copyMarkdown(meeting)
                    model.showFlash("copied")
                }
                .help("Copier les notes, vos notes et la transcription en Markdown")
                CapButton(title: "Supprimer", systemImage: "trash", tint: DS.Color.destructive) {
                    model.isConfirmingDelete = true
                }
            }
            .padding(.top, 34)
            .padding(.bottom, DS.Space.wide)

            if let message = model.bannerMessage {
                ProblemBanner(message: message, onDismiss: model.store.lastError == nil ? { model.dismissProblem() } : nil)
                    .padding(.bottom, DS.Space.base)
            }

            title.padding(.bottom, 8)

            HStack(spacing: DS.Space.roomy) {
                MetaItem(systemImage: "calendar", text: FrenchDates.fullDateTime(meeting.startedAt, calendar: FrenchDates.calendar))
                MetaItem(systemImage: "clock", text: FrenchFormat.duration(meeting.duration))
                if let appName { MetaItem(systemImage: "video", text: appName) }
                if meeting.trigger == .imported {
                    MetaItem(systemImage: "square.and.arrow.down", text: meeting.importedFrom.map { "Importée de \($0)" } ?? "Importée")
                    MetaItem(systemImage: "lock.fill", text: "Chiffré sur ce Mac")
                } else {
                    MetaItem(systemImage: "lock.fill", text: meeting.keepAudio ? "Chiffré sur ce Mac · audio conservé" : "Chiffré sur ce Mac · audio non conservé")
                }
            }
            .padding(.bottom, DS.Space.roomy)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DS.Space.snug) {
                    ForEach(meeting.speakers.filter { $0.id != Speaker.othersID || meeting.speakers.count == 2 }) { speaker in
                        ParticipantChip(model: model, speaker: speaker)
                    }
                    if let namesSource {
                        Text(namesSource)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.silkscreen)
                            .padding(.leading, DS.Space.tight)
                    }
                }
                .padding(2)
            }
            .padding(.bottom, DS.Space.wide)

            HStack {
                PillTabs(
                    options: MeetingLibraryModel.Tab.allCases,
                    title: \.title,
                    systemImage: { $0.symbol },
                    selection: model.tab
                ) { model.tab = $0 }
                Spacer()
                if model.tab == .transcript {
                    SearchWell(text: $model.transcriptQuery, placeholder: "Rechercher dans la transcription…", showsShortcut: false)
                        .frame(width: 280)
                } else if meeting.notes != nil {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles").font(.system(size: 10))
                        Text("Résumé généré sur ce Mac").font(DS.Font.caption)
                    }
                    .foregroundStyle(DS.Color.silkscreen)
                }
            }
        }
    }

    @ViewBuilder
    private var title: some View {
        if model.isEditingTitle {
            HStack(spacing: DS.Space.snug) {
                TextField("Titre", text: $model.titleDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(DS.Color.ink)
                    .padding(.horizontal, DS.Space.snug)
                    .padding(.vertical, DS.Space.tight)
                    .background(DS.Color.well, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                    .onSubmit { model.commitTitle() }
                    .onExitCommand { model.isEditingTitle = false }
                PrimaryButton(title: "Enregistrer", height: 28) { model.commitTitle() }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.snug) {
                Text(meeting.title.isEmpty ? "Réunion sans titre" : meeting.title)
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Button { model.beginEditingTitle() } label: {
                    Image(systemName: "pencil").font(.system(size: 12, weight: .semibold)).foregroundStyle(DS.Color.accent)
                }
                .buttonStyle(.plain)
                .help("Modifier le titre")
            }
        }
    }
}

private struct MetaItem: View {
    let systemImage: String
    let text: String
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: systemImage).font(.system(size: 10, weight: .medium))
            Text(text).font(DS.Font.caption).lineLimit(1)
        }
        .foregroundStyle(DS.Color.inkSecondary)
    }
}

/// A speaker; click to rename it everywhere in this meeting.
private struct ParticipantChip: View {
    @Bindable var model: MeetingLibraryModel
    let speaker: Speaker

    @State private var isHovered = false

    private var isRenaming: Bool { model.renaming?.id == speaker.id }

    var body: some View {
        Button { model.beginRenaming(speaker) } label: {
            HStack(spacing: 6) {
                Avatar(name: speaker.frenchDisplayName, size: 20, dashed: speaker.isUnnamed, isMe: speaker.isMe)
                Text(speaker.frenchDisplayName)
                    .font(DS.Font.label)
                    .foregroundStyle(speaker.isUnnamed ? DS.Color.inkSecondary : DS.Color.ink)
                if speaker.isUnnamed || isHovered {
                    Image(systemName: "pencil").font(.system(size: 9, weight: .semibold)).foregroundStyle(DS.Color.accent)
                }
            }
            .padding(.leading, 3)
            .padding(.trailing, 10)
            .frame(height: 26)
            .background(Capsule().fill(isRenaming ? DS.Color.selection : (speaker.isUnnamed ? DS.Color.panel : DS.Color.well)))
            .overlay(
                Capsule().strokeBorder(
                    isRenaming ? DS.Color.selectionEdge : (speaker.isUnnamed ? DS.Color.inkSecondary.opacity(0.45) : DS.Color.seam),
                    style: StrokeStyle(lineWidth: 1, dash: speaker.isUnnamed && !isRenaming ? [3, 2] : [])
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help("Renommer \(speaker.frenchDisplayName) partout dans cette réunion")
        .popover(isPresented: Binding(
            get: { isRenaming },
            set: { if !$0, isRenaming { model.renaming = nil } }
        ), arrowEdge: .bottom) {
            RenamePopover(model: model, speaker: speaker)
        }
    }
}

/// "Renommer « Intervenant 2 »" with the calendar's invitees as suggestions (mock-up 05).
private struct RenamePopover: View {
    @Bindable var model: MeetingLibraryModel
    let speaker: Speaker

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Text("Renommer \(FrenchFormat.quoted(speaker.frenchDisplayName))")
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
            TextField(speaker.frenchDisplayName, text: $model.renameDraft)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.Color.focusRing.opacity(isFocused ? 0.7 : 0.25), lineWidth: 1.5))
                .focused($isFocused)
                .onSubmit { model.commitRename() }

            let suggestions = model.renameSuggestions
            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Invités de l'agenda").font(DS.Font.silkscreen).foregroundStyle(DS.Color.silkscreen)
                    FlowRow(spacing: 6) {
                        ForEach(suggestions, id: \.self) { name in
                            let isChosen = model.renameDraft == name
                            Button { model.renameDraft = name } label: {
                                HStack(spacing: 5) {
                                    Avatar(name: name, size: 16, dashed: false)
                                    Text(name).font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(isChosen ? DS.Color.accent : DS.Color.ink)
                                }
                                .padding(.leading, 2).padding(.trailing, 8)
                                .frame(height: 22)
                                .background(isChosen ? DS.Color.selection : DS.Color.well, in: Capsule())
                                .overlay(Capsule().strokeBorder(isChosen ? DS.Color.selectionEdge : Color.clear, lineWidth: 0.75))
                                .contentShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(DS.Color.inkSecondary).padding(.top, 1)
                Text("Le nouveau nom remplace \(FrenchFormat.quoted(speaker.frenchDisplayName)) partout dans cette réunion : notes, transcription et export (\(FrenchFormat.count(model.interventions(of: speaker.id), "intervention"))). Laissez vide pour revenir à un intervenant numéroté.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Annuler") { model.renaming = nil }
                    .buttonStyle(.plain)
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .padding(.horizontal, 10)
                    .keyboardShortcut(.cancelAction)
                PrimaryButton(title: "Renommer", height: 28) { model.commitRename() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.roomy)
        .frame(width: 330)
        .onAppear { isFocused = true }
    }
}

/// Lays children out left to right, wrapping onto new lines.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + spacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            line = max(line, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + spacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}

// MARK: - Notes tab

private struct NotesTab: View {
    @Bindable var model: MeetingLibraryModel
    let meeting: Meeting

    var body: some View {
        if let notes = meeting.notes {
            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.panel) {
                    RegeneratingLine(model: model)

                    VStack(alignment: .leading, spacing: DS.Space.snug) {
                        NoteSectionTitle(systemImage: "text.alignleft", title: "Récap")
                        Text(notes.recap)
                            .font(DS.Font.body)
                            .foregroundStyle(DS.Color.ink)
                            .lineSpacing(4)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        NoteSectionTitle(systemImage: "checklist", title: "Prochaines étapes").padding(.bottom, 4)
                        if notes.nextSteps.isEmpty {
                            Text("Aucune prochaine étape.").font(DS.Font.body).foregroundStyle(DS.Color.inkSecondary)
                        }
                        ForEach(Array(notes.nextSteps.enumerated()), id: \.offset) { index, step in
                            if index > 0 { RowDivider(inset: 28) }
                            ActionRow(step: step, meeting: meeting)
                        }
                    }

                    BulletSection(systemImage: "checkmark.seal", title: "Décisions", items: notes.decisions, none: "Aucune décision enregistrée.")
                    if !notes.openQuestions.isEmpty {
                        BulletSection(systemImage: "questionmark.circle", title: "Questions ouvertes", items: notes.openQuestions, none: "")
                    }

                    NotesProvenance(model: model, notes: notes, meeting: meeting)
                }
                .frame(maxWidth: DS.Window.readingWidth - 40, alignment: .leading)
                .padding(.horizontal, DS.Space.panel + 4)
                .padding(.top, DS.Space.panel)
                .padding(.bottom, DS.Space.panel)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            NotesStatusPanel(model: model, meeting: meeting)
        }
    }
}

private struct NoteSectionTitle: View {
    let systemImage: String
    let title: String
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.Color.accent)
            Text(title).font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.ink)
        }
    }
}

/// One next step: the first word in bold, the owner, the due date. The notes do not record
/// whether a step is done, so the circle is a bullet, not a checkbox.
private struct ActionRow: View {
    let step: ActionItem
    let meeting: Meeting

    private var verb: String { step.text.split(separator: " ", maxSplits: 1).first.map(String.init) ?? step.text }
    private var rest: String {
        let parts = step.text.split(separator: " ", maxSplits: 1)
        return parts.count > 1 ? " " + parts[1] : ""
    }

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Circle()
                .strokeBorder(DS.Color.inkSecondary.opacity(0.45), lineWidth: 1.2)
                .frame(width: 16, height: 16)
            Text("\(Text(verb).fontWeight(.semibold))\(rest)")
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: DS.Space.base)
            if let owner = step.owner, !owner.isEmpty {
                let shown = SpeakerLabel.french(displayName: owner)
                HStack(spacing: 5) {
                    Avatar(name: shown, size: 16, isMe: isMe(owner))
                    Text(shown).font(.system(size: 11, weight: .medium)).foregroundStyle(DS.Color.ink)
                }
                .padding(.leading, 2).padding(.trailing, 8)
                .frame(height: 20)
                .background(DS.Color.well, in: Capsule())
            }
            if let due = step.due, !due.isEmpty {
                Text(due).font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary).frame(minWidth: 70, alignment: .trailing)
            }
        }
        .padding(.vertical, 7)
    }

    private func isMe(_ owner: String) -> Bool {
        let me = meeting.speakers.first(where: \.isMe)
        return owner == "Vous" || owner == "You" || owner == me?.name
    }
}

private struct BulletSection: View {
    let systemImage: String
    let title: String
    let items: [String]
    let none: String

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.snug) {
            NoteSectionTitle(systemImage: systemImage, title: title)
            if items.isEmpty {
                Text(none).font(DS.Font.body).foregroundStyle(DS.Color.inkSecondary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(DS.Color.accent).frame(width: 5, height: 5).offset(y: -2)
                    Text(item)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.ink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 6)
            }
        }
    }
}

/// Who wrote the notes and when, the template, and *Régénérer*.
private struct NotesProvenance: View {
    @Bindable var model: MeetingLibraryModel
    let notes: MeetingNotes
    let meeting: Meeting

    var body: some View {
        HStack(spacing: DS.Space.snug) {
            Text("Rédigé sur ce Mac par \(notes.modelDisplayName), \(FrenchDates.relativeDayTime(notes.generatedAt, now: Date(), calendar: FrenchDates.calendar).lowercasedFirst).")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.silkscreen)
            Spacer()
            TemplateMenu(model: model)
            CapButton(title: "Régénérer", systemImage: "arrow.clockwise", height: 26, isEnabled: !model.generator.isBusy(meeting.id)) {
                model.requestRegenerate()
            }
            .help("Rédiger de nouvelles notes à partir de la transcription ; elles remplacent les actuelles")
        }
        .padding(.top, DS.Space.snug)
    }
}

private struct TemplateMenu: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        MenuChip(title: "Modèle : \(model.template.frenchTitle)") {
            ForEach(NotesTemplate.allCases, id: \.self) { template in
                Button(template.frenchTitle) { model.setTemplate(template) }
            }
        }
        .help("Le modèle de notes utilisé à la prochaine rédaction")
    }
}

extension String {
    /// "Aujourd'hui, 10:00" → "aujourd'hui, 10:00", inside a sentence.
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// In place of the notes while there are none: writing, failed, or not written.
private struct NotesStatusPanel: View {
    @Bindable var model: MeetingLibraryModel
    let meeting: Meeting

    var body: some View {
        VStack(spacing: DS.Space.base) {
            switch model.status {
            case .queued:
                EmptyState(systemImage: "hourglass", title: "Notes en attente", detail: "Les notes d'une autre réunion sont en cours de rédaction.")
            case .working(let progress):
                VStack(spacing: DS.Space.snug) {
                    ProgressView().controlSize(.small)
                    Text("Rédaction des notes").font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.ink)
                    Text(Self.describe(progress)).font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                EmptyState(systemImage: "exclamationmark.triangle", title: "Pas de notes", detail: message, actionTitle: "Réessayer") {
                    model.regenerate()
                }
            case nil:
                EmptyState(
                    systemImage: "text.badge.star",
                    title: "Pas encore de notes",
                    detail: FoundationModelFormatter.unavailableReason.map { "Les notes nécessitent le modèle local : \($0)" }
                        ?? "Les notes de cette réunion n'ont pas encore été rédigées. La transcription est complète.",
                    actionTitle: "Rédiger les notes"
                ) {
                    model.regenerate()
                }
            }
            HStack {
                Spacer()
                TemplateMenu(model: model)
            }
            .padding(DS.Space.roomy)
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

/// While a regeneration runs, the existing notes stay with a status line above.
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
        Text(text).font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
    }
}

// MARK: - Transcript tab

private struct TranscriptTab: View {
    @Bindable var model: MeetingLibraryModel
    let meeting: Meeting

    private var segments: [TranscriptSegment] {
        let sorted = meeting.segments.sorted { $0.start < $1.start }
        let query = model.transcriptQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return sorted }
        return sorted.filter {
            $0.text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || (meeting.speaker($0.speakerID)?.frenchDisplayName ?? "")
                    .range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var body: some View {
        if meeting.segments.isEmpty {
            EmptyState(systemImage: "text.quote", title: "Pas de transcription", detail: "Rien n'a été transcrit pendant cette réunion.")
        } else if segments.isEmpty {
            EmptyState(systemImage: "magnifyingglass", title: "Aucun résultat", detail: "Rien dans la transcription ne correspond à cette recherche.")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(segments) { segment in
                        UtteranceRow(model: model, meeting: meeting, segment: segment)
                    }
                }
                .frame(maxWidth: DS.Window.readingWidth, alignment: .leading)
                .padding(.horizontal, DS.Space.roomy)
                .padding(.vertical, DS.Space.base)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct UtteranceRow: View {
    @Bindable var model: MeetingLibraryModel
    let meeting: Meeting
    let segment: TranscriptSegment

    private var speaker: Speaker { meeting.speaker(segment.speakerID) ?? Speaker(id: segment.speakerID) }
    private var isHighlighted: Bool { model.renaming?.id == speaker.id }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.base) {
            Button { model.beginRenaming(speaker) } label: {
                Avatar(name: speaker.frenchDisplayName, size: 28, dashed: speaker.isUnnamed, isMe: speaker.isMe)
            }
            .buttonStyle(.plain)
            .help("Renommer \(speaker.frenchDisplayName) partout dans cette réunion")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: DS.Space.snug) {
                    Text(speaker.frenchDisplayName).font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.ink)
                    Text(FrenchFormat.timecode(segment.start))
                        .font(.system(size: 11, weight: .medium, design: .rounded).monospacedDigit())
                        .foregroundStyle(DS.Color.silkscreen)
                }
                Text(segment.text)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.ink.opacity(segment.isFinal ? 1 : DS.Library.inkDim))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, 10)
        .background {
            if isHighlighted {
                RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Color.selection.opacity(0.6))
            }
        }
    }
}

// MARK: - My notes tab

private struct MyNotesTab: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $model.notesDraft)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.ink)
                .scrollContentBackground(.hidden)
                .padding(DS.Space.roomy)
                .frame(maxWidth: DS.Window.readingWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            ListFooter(text: "Ce que vous avez saisi pendant la réunion — les notes le considèrent comme le plus important") {
                CapButton(title: model.hasUnsavedNotes ? "Enregistrer" : "Enregistré", height: 24, isEnabled: model.hasUnsavedNotes) {
                    model.saveUserNotes()
                }
                .keyboardShortcut("s", modifiers: .command)
            }
        }
    }
}
