import FluenceNotesCore
import SwiftUI

/// The meetings library: every recorded meeting, newest first, searchable, with its notes
/// and transcript.
///
/// Laid out like the main window: a panel across the top, then the list in a recessed well
/// on the left and the selected meeting on the right — its own panel of facts and keys, a
/// row of section keys, and a well holding the section.
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
                    Well {
                        MeetingList(model: model)
                            .padding(DS.Space.hair)
                    }
                    .frame(width: DS.Library.listWidth)

                    if model.meeting != nil {
                        MeetingDetail(model: model)
                    } else {
                        Well {
                            EmptyPanel(
                                label: model.store.summaries.isEmpty ? "No meetings yet" : "No meeting selected",
                                detail: model.store.summaries.isEmpty
                                    ? "Meetings appear here once Fluence has taken notes."
                                    : "Choose one on the left."
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

// MARK: - Header

private struct LibraryHeader: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        HStack(spacing: DS.Space.roomy) {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Silkscreen(text: "Meetings", large: true)
                Silkscreen(text: "Notes on this Mac only")
            }

            LabeledFact(label: "Count") {
                DeckWindow {
                    Readout(text: String(format: "%03d", model.store.summaries.count))
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.tight)
                }
            }

            Spacer()

            LibraryHeaderAccessories(model: model)

            Vents(count: 6)
            VStack(spacing: DS.Space.snug) {
                Screw()
                Screw()
            }
        }
        .padding(DS.Space.roomy)
        .background(BrushedPanel())
    }
}

// MARK: - List

private struct MeetingList: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $model.query, placeholder: "Search meetings")

            if model.visible.isEmpty {
                EmptyPanel(
                    label: model.store.summaries.isEmpty ? "No meetings" : "No matches",
                    detail: model.store.summaries.isEmpty
                        ? "Nothing recorded yet."
                        : "Titles, names, notes and transcripts are searched."
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
                Silkscreen(
                    text: model.searchHits == nil
                        ? "\(model.store.summaries.count) meeting\(model.store.summaries.count == 1 ? "" : "s")"
                        : "\(model.visible.count) found",
                    color: DS.Color.inkOnDeck.opacity(DS.Library.inkFaint)
                )
                Spacer()
            }
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.snug)
            .background(DS.Color.deck)
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
                    Text(summary.title.isEmpty ? "Untitled meeting" : summary.title)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.inkOnDeck)
                        .lineLimit(1)
                    Spacer(minLength: DS.Space.tight)
                    // Lit: notes written. The lamp is the same instrument as the dictionary's
                    // "enabled" lamp.
                    Lamp(color: DS.Color.meterGreen, isLit: summary.hasNotes, size: DS.Library.lampSmall)
                        .help(summary.hasNotes ? "Notes written" : (isWriting ? "Writing notes…" : "No notes"))
                }
                HStack(spacing: DS.Space.snug) {
                    Text(summary.startedAt, format: .dateTime.day().month(.abbreviated).year().hour().minute())
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkOnDeck.opacity(DS.Library.inkDim))
                    Readout(text: DurationText.format(summary.duration))
                        .foregroundStyle(DS.Color.inkOnDeck.opacity(DS.Library.inkDim))
                }
                if !summary.speakerNames.isEmpty {
                    Text(summary.speakerNames.joined(separator: ", "))
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkOnDeck.opacity(DS.Library.inkFaint))
                        .lineLimit(1)
                }
                if isWriting {
                    Silkscreen(text: "Writing notes", color: DS.Color.inkOnDeck.opacity(DS.Library.inkDim))
                }
            }
            .padding(DS.Space.base)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                DeckWindow { Color.clear }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: DS.Radius.panel)
                        .strokeBorder(DS.Color.selectionEdge, lineWidth: DS.Border.bevel)
                }
            }
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

                Well {
                    Group {
                        switch model.tab {
                        case .recap: RecapSection(model: model, meeting: meeting)
                        case .nextSteps: NextStepsSection(model: model, meeting: meeting)
                        case .decisions: DecisionsSection(model: model, meeting: meeting)
                        case .transcript: TranscriptSection(model: model, meeting: meeting)
                        case .myNotes: MyNotesSection(model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(DS.Color.deck)
                    .padding(DS.Space.hair)
                }
                .frame(maxHeight: .infinity)
            }
            .sheet(item: $model.renaming) { _ in
                RenameSpeakerSheet(model: model)
            }
            .confirmationDialog(
                "Delete “\(meeting.title)”?",
                isPresented: $model.isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("Delete Meeting", role: .destructive) { model.deleteSelected() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its transcript, notes and any kept audio are erased with their encryption key. This can't be undone.")
            }
            .confirmationDialog(
                "Replace these notes?",
                isPresented: $model.isConfirmingRegenerate,
                titleVisibility: .visible
            ) {
                Button("Regenerate Notes") { model.regenerate() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("New notes are written from the transcript with the \(model.template.title) template and "
                    + "replace the current ones once they're ready. If writing fails, the current notes stay.")
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
                    TextField("Title", text: $model.titleDraft)
                        .textFieldStyle(.plain)
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Color.inkOnDeck)
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.tight)
                        .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
                        .onSubmit { model.commitTitle() }
                        .onExitCommand { model.isEditingTitle = false }
                    TransportKey(title: "Save", isEngaged: true, engagedColor: DS.Color.ink) { model.commitTitle() }
                } else {
                    Text(meeting.title.isEmpty ? "Untitled meeting" : meeting.title)
                        .font(DS.Font.title)
                        .foregroundStyle(DS.Color.ink)
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Button { model.beginEditingTitle() } label: {
                        Silkscreen(text: "Edit title", color: DS.Color.inkSecondary)
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
                LabeledFact(label: "Length") {
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
                LabeledFact(label: "Notes template") {
                    SelectorKeys(
                        options: NotesTemplate.allCases,
                        title: \.title,
                        selection: model.template
                    ) { model.setTemplate($0) }
                }
                Spacer()
                TransportKey(
                    title: meeting.notes == nil ? "Write notes" : "Regenerate notes",
                    systemImage: "text.badge.star",
                    isEnabled: !model.generator.isBusy(meeting.id)
                ) {
                    model.requestRegenerate()
                }
                .help(meeting.notes == nil
                    ? "Write notes with the on-device model"
                    : "Write new notes from the transcript; they replace the current ones")
            }

            HStack(spacing: DS.Space.snug) {
                MeetingExportKeys(model: model, meeting: meeting)
                Spacer()
                TransportKey(title: "Delete", systemImage: "trash") {
                    model.isConfirmingDelete = true
                }
                .help("Delete this meeting")
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
                statusLine(lit: true, label: "Notes queued", detail: "Another meeting's notes are being written first.")
            case .working(let progress):
                statusLine(lit: true, label: "Writing notes", detail: Self.describe(progress))
            case .failed(let message):
                statusLine(lit: false, label: "No notes", detail: message)
                DeckKey(title: "Try again", systemImage: "arrow.clockwise") { model.regenerate() }
            case nil:
                statusLine(
                    lit: false,
                    label: "No notes",
                    detail: FoundationModelFormatter.unavailableReason.map { "Notes need the on-device model: \($0)" }
                        ?? "Notes haven't been written for this meeting. The transcript is complete."
                )
                DeckKey(title: "Write notes", systemImage: "text.badge.star") { model.regenerate() }
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
                Silkscreen(text: label, color: DS.Color.inkOnDeck)
                Text(detail)
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkOnDeck.opacity(DS.Library.inkDim))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func describe(_ progress: NotesProgress) -> String {
        switch progress {
        case .preparing: "Preparing the transcript…"
        case .reading(let index, let count): "Reading part \(index) of \(count)…"
        case .merging: "Merging what each part said…"
        case .writing: "Writing the final notes…"
        }
    }
}

/// While a regeneration runs, existing notes stay on screen with a status line above.
private struct RegeneratingLine: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        if case .working(let progress) = model.status {
            line("Rewriting notes — " + NotesStatusPanel.describe(progress))
        } else if case .queued = model.status {
            line("Rewriting notes — queued")
        } else if case .failed(let message) = model.status {
            line(message)
        }
    }

    private func line(_ text: String) -> some View {
        Silkscreen(text: text, color: DS.Color.inkOnDeck.opacity(DS.Library.inkDim))
            .padding(.horizontal, DS.Space.roomy)
            .padding(.top, DS.Space.base)
    }
}

/// Scrolling deck content with the notes' provenance at the bottom.
private struct NotesPage<Content: View>: View {
    @Bindable var model: MeetingLibraryModel
    let notes: MeetingNotes
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.Space.roomy) {
                content
                Text("Written on this Mac by \(notes.model), \(notes.generatedAt.formatted(date: .abbreviated, time: .shortened)).")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkOnDeck.opacity(DS.Library.inkFaint))
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
                    .foregroundStyle(DS.Color.inkOnDeck)
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
                    Silkscreen(text: "No next steps", color: DS.Color.inkOnDeck.opacity(DS.Library.inkFaint))
                }
                ForEach(Array(notes.nextSteps.enumerated()), id: \.offset) { _, step in
                    HStack(alignment: .firstTextBaseline, spacing: DS.Space.snug) {
                        Image(systemName: "square")
                            .font(.system(size: DS.Library.glyphLarge, weight: .regular))
                            .foregroundStyle(DS.Color.inkOnDeck.opacity(DS.Library.inkDim))
                        VStack(alignment: .leading, spacing: DS.Space.hair) {
                            Text(step.text)
                                .font(DS.Font.body)
                                .foregroundStyle(DS.Color.inkOnDeck)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            HStack(spacing: DS.Space.snug) {
                                if let owner = step.owner {
                                    Silkscreen(text: owner, color: DS.Color.inkOnDeck.opacity(DS.Library.inkDim))
                                }
                                if let due = step.due {
                                    Silkscreen(text: "Due " + due, color: DS.Color.inkOnDeck.opacity(DS.Library.inkFaint))
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
                BulletGroup(label: "Decisions", items: notes.decisions, none: "No decisions recorded")
                BulletGroup(label: "Open questions", items: notes.openQuestions, none: "No open questions")
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
            Silkscreen(text: label, color: DS.Color.inkOnDeck.opacity(DS.Library.inkDim))
            if items.isEmpty {
                Text(none)
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkOnDeck.opacity(DS.Library.inkFaint))
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: DS.Space.snug) {
                    Text("—")
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.inkOnDeck.opacity(DS.Library.inkFaint))
                    Text(item)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.inkOnDeck)
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
                EmptyPanel(label: "No transcript", detail: "Nothing was transcribed in this meeting.")
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
                Silkscreen(text: "Speakers", color: DS.Color.inkOnDeck.opacity(DS.Library.inkFaint))
                ForEach(meeting.speakers) { speaker in
                    Button { model.beginRenaming(speaker) } label: {
                        HStack(spacing: DS.Space.tight) {
                            Text(speaker.displayName)
                                .font(DS.Font.label)
                                .foregroundStyle(DS.Color.inkOnDeck)
                            Silkscreen(
                                text: Self.source(speaker),
                                color: DS.Color.inkOnDeck.opacity(DS.Library.inkFaint)
                            )
                        }
                        .padding(.horizontal, DS.Space.snug)
                        .padding(.vertical, DS.Space.tight)
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.chip)
                                .strokeBorder(DS.Color.inkOnDeck.opacity(DS.Library.edgeFaint), lineWidth: DS.Border.hairline)
                        )
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help("Rename \(speaker.displayName) everywhere in this meeting")
                }
            }
            .padding(.horizontal, DS.Space.roomy)
            .padding(.vertical, DS.Space.snug)
        }
        .background(DS.Color.deck)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.Color.seam).frame(height: DS.Border.seam)
        }
    }

    private func row(_ segment: TranscriptSegment) -> some View {
        let speaker = meeting.speaker(segment.speakerID) ?? Speaker(id: segment.speakerID)
        return HStack(alignment: .firstTextBaseline, spacing: DS.Space.base) {
            Text(Clock.format(segment.start))
                .font(DS.Font.counter)
                .foregroundStyle(DS.Color.inkOnDeck.opacity(DS.Library.inkFaint))
                .frame(width: DS.Library.timestampWidth, alignment: .leading)
            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Button { model.beginRenaming(speaker) } label: {
                    Text(speaker.displayName)
                        .font(DS.Font.bodyEmphasis)
                        .foregroundStyle(DS.Color.inkOnDeck)
                }
                .buttonStyle(.plain)
                .help("Rename \(speaker.displayName) everywhere in this meeting")
                Text(segment.text)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkOnDeck.opacity(segment.isFinal ? 1 : DS.Library.inkDim))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    static func source(_ speaker: Speaker) -> String {
        switch speaker.nameSource {
        case .user: "named by you"
        case .meetingWindow: "from the call"
        case .voicePrint: "voice print"
        case .calendar: "calendar"
        case nil: speaker.isMe ? "mic" : "unnamed"
        }
    }
}

private struct RenameSpeakerSheet: View {
    @Bindable var model: MeetingLibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            Silkscreen(text: "Rename speaker", large: true)
            Text("The new name applies to every line this speaker said in this meeting, and to "
                + "their next steps. Leave it empty to go back to a numbered speaker.")
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                Silkscreen(text: "Name")
                TextField(model.renaming?.displayName ?? "Name", text: $model.renameDraft)
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkOnDeck)
                    .padding(DS.Space.snug)
                    .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.chip)
                            .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                    )
                    .onSubmit { model.commitRename() }
            }
            HStack(spacing: DS.Space.snug) {
                Spacer()
                TransportKey(title: "Cancel") { model.renaming = nil }
                TransportKey(title: "Rename", isEngaged: true, engagedColor: DS.Color.ink) { model.commitRename() }
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
                .foregroundStyle(DS.Color.inkOnDeck)
                .scrollContentBackground(.hidden)
                .padding(DS.Space.base)
                .frame(minHeight: DS.Library.editorMinHeight)

            HStack(spacing: DS.Space.snug) {
                Silkscreen(
                    text: "What you typed during the meeting — the notes treat it as most important",
                    color: DS.Color.inkOnDeck.opacity(DS.Library.inkFaint)
                )
                Spacer()
                DeckKey(title: model.hasUnsavedNotes ? "Save" : "Saved", isEnabled: model.hasUnsavedNotes) {
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
