import FluenceCore
import SwiftUI

/// "Importer une réunion" (FLU-16): files or pasted text first, then one confirmation per
/// transcript (title, date, which speaker is the user, a preview of the first turns).
struct MeetingImportSheet: View {
    @Bindable var importer: MeetingImportModel
    let onImported: (UUID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            if let draft = importer.draft {
                DraftForm(importer: importer, draft: draft, onImported: onImported)
            } else {
                SourceStep(importer: importer)
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 520)
        .background(DS.Color.chassis)
        .fileImporter(
            isPresented: $importer.isChoosingFiles,
            allowedContentTypes: MeetingImportModel.fileTypes,
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result { importer.open(urls) }
        }
    }
}

// MARK: - Step 1: where the transcript comes from

private struct SourceStep: View {
    @Bindable var importer: MeetingImportModel
    @FocusState private var isEditing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Importer une réunion")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(DS.Color.ink)
            Text("Ajoutez une réunion passée à vos réunions : Fluence en tire les notes, comme pour une réunion enregistrée.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack(spacing: DS.Space.base) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(DS.Color.accent)
                .frame(width: 40, height: 40)
                .background(DS.Color.selection, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text("Un ou plusieurs fichiers").font(DS.Font.bodyEmphasis).foregroundStyle(DS.Color.ink)
                Text("Texte (.txt), Markdown, sous-titres Zoom ou Teams (.vtt), .srt. Vous pouvez aussi les glisser sur la liste des réunions.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.Space.snug)
            CapButton(title: "Choisir…", systemImage: "folder") { importer.isChoosingFiles = true }
        }
        .padding(DS.Space.base)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DS.Color.panel)
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline))
        )

        VStack(alignment: .leading, spacing: 6) {
            Text("Ou collez la transcription").font(DS.Font.silkscreen).foregroundStyle(DS.Color.silkscreen)
            TextEditor(text: $importer.pastedText)
                .font(DS.Font.body)
                .scrollContentBackground(.hidden)
                .focused($isEditing)
                .frame(height: 150)
                .padding(8)
                .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(DS.Color.focusRing.opacity(isEditing ? 0.7 : 0.25), lineWidth: 1.5)
                )
            Text("Une intervention par ligne, par exemple « Alice : On valide le budget. »")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
        }

        ProblemLine(text: importer.problem)

        HStack {
            Spacer()
            Button("Annuler") { importer.cancel() }
                .buttonStyle(.plain)
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
                .padding(.horizontal, 10)
                .keyboardShortcut(.cancelAction)
            PrimaryButton(
                title: "Continuer",
                height: 28,
                isEnabled: !importer.pastedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ) { importer.usePastedText() }
                .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Step 2: confirm one transcript

private struct DraftForm: View {
    @Bindable var importer: MeetingImportModel
    let draft: MeetingImportModel.Draft
    let onImported: (UUID) -> Void

    @FocusState private var isEditingTitle: Bool
    @State private var store = MeetingStore.shared
    @State private var generator = MeetingNotesGenerator.shared

    private var transcript: ImportedTranscript { draft.transcript }

    /// What the meeting will look like, computed exactly as it will be saved.
    private var preview: Meeting {
        TranscriptImport.meeting(from: transcript, title: draft.title, startedAt: draft.date, me: draft.me)
    }

    private var summaryLine: String {
        let meeting = preview
        var parts = [FrenchFormat.count(meeting.segments.count, "intervention")]
        if !transcript.speakers.isEmpty {
            parts.append(FrenchFormat.count(transcript.speakers.count, "participant"))
        }
        let length = FrenchFormat.duration(meeting.duration)
        parts.append(transcript.isTimed ? length : "environ \(length) (durée estimée)")
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.sourceName.map { "Importer \(FrenchFormat.quoted($0))" } ?? "Importer le texte collé")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(summaryLine).font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
            }
            Spacer()
            if let position = importer.position {
                MetaChip(text: "\(position.index) sur \(position.count)", systemImage: "doc.on.doc")
            }
        }

        HStack(alignment: .top, spacing: DS.Space.base) {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Titre")
                TextField("Réunion importée", text: Binding(
                    get: { importer.draft?.title ?? "" },
                    set: { importer.draft?.title = $0 }
                ))
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.Color.focusRing.opacity(isEditingTitle ? 0.7 : 0.25), lineWidth: 1.5))
                .focused($isEditingTitle)
            }
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Date")
                DatePicker("Date", selection: Binding(
                    get: { importer.draft?.date ?? Date() },
                    set: { importer.draft?.date = $0 }
                ), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .datePickerStyle(.compact)
                .environment(\.locale, Locale(identifier: "fr_FR"))  // the UI is French whatever the system language
                .frame(height: 30)
            }
            .fixedSize()
        }

        if !transcript.speakers.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                FieldLabel(text: "Qui êtes-vous dans cette réunion ?")
                FlowRow(spacing: 6) {
                    ForEach(transcript.speakers, id: \.self) { name in
                        SpeakerChoice(name: name, isChosen: draft.me == name) { importer.draft?.me = name }
                    }
                    SpeakerChoice(name: "Personne", isChosen: draft.me == nil, showsAvatar: false) { importer.draft?.me = nil }
                }
                Text("Vos interventions seront à votre nom, les autres gardent le nom écrit dans le fichier. Vous pourrez renommer chacun ensuite.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }

        VStack(alignment: .leading, spacing: 6) {
            FieldLabel(text: "Aperçu")
            VStack(alignment: .leading, spacing: 6) {
                let meeting = preview
                ForEach(meeting.segments.prefix(4)) { segment in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(FrenchFormat.clock(segment.start))
                            .font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(DS.Color.silkscreen)
                            .frame(width: 40, alignment: .leading)
                        let name = meeting.speaker(segment.speakerID)?.frenchDisplayName ?? ""
                        let speaker = Text(name)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(segment.speakerID == Speaker.meID ? DS.Color.accent : DS.Color.ink)
                        let words = Text(segment.text).font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
                        Text("\(speaker)  \(words)").lineLimit(2)
                    }
                }
                if meeting.segments.count > 4 {
                    Text("… et \(FrenchFormat.count(meeting.segments.count - 4, "autre intervention", "autres interventions"))")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.silkscreen)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        }

        ProblemLine(text: importer.problem)

        HStack(spacing: 6) {
            Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(DS.Color.inkSecondary)
            Text("Chiffrée sur ce Mac, comme vos réunions enregistrées. Le fichier d'origine n'est pas modifié.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.inkSecondary)
        }

        HStack {
            if importer.position != nil {
                Button("Passer ce fichier") { importer.skip() }
                    .buttonStyle(.plain)
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            Spacer()
            Button("Annuler") { importer.cancel() }
                .buttonStyle(.plain)
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
                .padding(.horizontal, 10)
                .keyboardShortcut(.cancelAction)
            PrimaryButton(title: "Importer", systemImage: "square.and.arrow.down", height: 28) {
                let wasLast = importer.position.map { $0.index == $0.count } ?? true
                if let id = importer.commit(store: store, generator: generator), wasLast {
                    onImported(id)
                }
            }
            .keyboardShortcut(.defaultAction)
        }
    }
}

// MARK: - Pieces

private struct FieldLabel: View {
    let text: String

    var body: some View {
        Text(text).font(DS.Font.silkscreen).foregroundStyle(DS.Color.silkscreen)
    }
}

private struct SpeakerChoice: View {
    let name: String
    let isChosen: Bool
    var showsAvatar = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if showsAvatar { Avatar(name: name, size: 16, dashed: false) }
                Text(name).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isChosen ? DS.Color.accent : DS.Color.ink)
            }
            .padding(.leading, showsAvatar ? 2 : 8).padding(.trailing, 8)
            .frame(height: 22)
            .background(isChosen ? DS.Color.selection : DS.Color.well, in: Capsule())
            .overlay(Capsule().strokeBorder(isChosen ? DS.Color.selectionEdge : Color.clear, lineWidth: 0.75))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct ProblemLine: View {
    let text: String?

    var body: some View {
        if let text {
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(DS.Color.inkSecondary)
                    .padding(.top, 1)
                Text(text)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
