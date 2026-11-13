import AppKit
import FluenceCore
import FluenceDictionary
import SwiftUI

/// Dictionnaire (FLU-12): the words Fluence must write right — add, edit, delete, search.
///
/// A term and a correction are two ways of teaching Fluence the same word, and everything it
/// was taught should be visible at once, so both kinds share one list with no tabs. The kind is
/// shown by
/// a tag on each row.
struct DictionaryPanel: View {
    /// What the « Lexique Tech » button just did, shown on it for a moment (FLU-17).
    @State private var lexiconResult: String?
    @State private var store = DictionaryStore.shared
    @State private var query = ""
    @State private var editing: DictionaryEntry?
    @State private var isAdding = false
    @State private var isReviewingSuspects = false
    /// What « Scanner un projet… » found, for the user to tick before anything is added.
    @State private var scanned: [DictionaryEntry]?

    private var entries: [DictionaryEntry] { store.filtered(by: query) }

    /// Adds the tech lexicon's missing entries and says how many; reads « à jour » once there
    /// is nothing left to add, instead of a button that silently does nothing (FLU-17).
    private var lexiconButton: some View {
        let missing = store.missingTechLexiconCount
        let title = lexiconResult ?? (missing == 0 ? "Lexique Tech à jour" : "Lexique Tech")
        return CapButton(
            title: title,
            systemImage: missing == 0 || lexiconResult != nil ? "checkmark" : "sparkles",
            isEnabled: missing > 0
        ) {
            let added = store.importTechLexicon()
            lexiconResult = added == 0 ? "Déjà à jour" : "+ " + FrenchFormat.count(added, "entrée ajoutée", "entrées ajoutées")
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                lexiconResult = nil
            }
        }
        .help(missing == 0
            ? "Rien à ajouter du lexique : techniques, Git et anglicismes."
            : "Ajouter \(FrenchFormat.count(missing, "entrée")) du lexique : techniques, Git et anglicismes.")
    }

    /// Shown only while the dictionary still holds lexicon entries that rewrote ordinary
    /// French (« le colle » → « le call »), as seeded: one click removes them (FLU-30).
    @ViewBuilder private var retiredLexiconButton: some View {
        let retired = store.retiredLexiconEntries
        if !retired.isEmpty {
            CapButton(title: "Retirer de mon dictionnaire", systemImage: "minus.circle") {
                store.removeRetiredLexiconEntries()
            }
            .help("Retirer \(FrenchFormat.count(retired.count, "entrée")) de l'ancien Lexique Tech qui "
                + "réécrivai\(retired.count > 1 ? "ent" : "t") des mots courants : "
                + retired.map { "\($0.hear) → \($0.write)" }.joined(separator: ", ") + ".")
        }
    }

    /// Terms the old « termes fréquents » most likely added by mistake (FLU-88): « prêt. », « Je ».
    private var suspects: [DictionaryEntry] {
        store.entries.filter { $0.kind == .term && FrequentTerms.isSuspect($0.write) }
    }

    /// One line while there are suspects; the user reviews them, nothing is removed for them.
    @ViewBuilder private var suspectLine: some View {
        let count = suspects.count
        if count > 0 {
            HStack(spacing: DS.Space.snug) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.Color.meterAmber)
                    .accessibilityHidden(true)
                Text(FrenchFormat.count(count, "terme appris par erreur", "termes appris par erreur"))
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.amberText)
                Spacer()
                CapButton(title: "Revoir", height: 24) { isReviewingSuspects = true }
            }
            .padding(.horizontal, DS.Space.panel)
            .padding(.bottom, DS.Space.base)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Dictionnaire",
                subtitle: FrenchFormat.count(store.entries.count, "entrée")
            ) {
                retiredLexiconButton
                lexiconButton
                CapButton(title: "Scanner un projet…", systemImage: "folder.badge.plus") { scanFolder() }
                    .help("Scanner un dossier de code pour en extraire le vocabulaire")
                CapButton(title: "Ajouter", systemImage: "plus") { isAdding = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            .padding(.horizontal, DS.Space.panel)
            .padding(.top, 28)
            .padding(.bottom, DS.Space.roomy)

            SearchWell(text: $query, placeholder: "Rechercher dans le dictionnaire…")
                .padding(.horizontal, DS.Space.panel)
                .padding(.bottom, DS.Space.base)

            suspectLine

            if entries.isEmpty {
                EmptyState(
                    systemImage: store.entries.isEmpty ? "book.closed" : "magnifyingglass",
                    title: store.entries.isEmpty ? "Dictionnaire vide" : "Aucun résultat",
                    detail: store.entries.isEmpty
                        ? "Ajoutez les mots que Fluence écrit mal : un nom, une marque, un terme technique."
                        : "Essayez une autre recherche.",
                    actionTitle: store.entries.isEmpty ? "Ajouter un mot" : nil,
                    action: store.entries.isEmpty ? { isAdding = true } : nil
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.tight) {
                        ForEach(entries) { entry in
                            DictionaryRow(
                                entry: entry,
                                onEdit: { editing = entry },
                                onToggle: {
                                    var flipped = entry
                                    flipped.isEnabled.toggle()
                                    store.update(flipped)
                                },
                                onDelete: { store.delete(entry) }
                            )
                        }
                    }
                    .padding(.horizontal, DS.Space.panel)
                    .padding(.bottom, DS.Space.roomy)
                }
            }

            // The file path is shown because the dictionary is meant to be editable outside
            // the UI — which is only true if you can find it.
            ListFooter(text: FrenchFormat.count(store.entries.count, "entrée")) {
                if let problem = store.problem {
                    Text(problem).font(DS.Font.caption).foregroundStyle(DS.Color.faultText).lineLimit(2)
                }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([DictionaryStore.fileURL])
                } label: {
                    Text("Afficher dictionary.txt dans le Finder").font(DS.Font.caption).foregroundStyle(DS.Color.inkSecondary)
                }
                .buttonStyle(.plain)
                .help(DictionaryStore.fileURL.path)
            }
        }
        .sheet(isPresented: $isAdding) {
            DictionaryEditor(entry: nil) { newEntry in
                store.add(newEntry)
            }
        }
        .sheet(isPresented: $isReviewingSuspects) {
            EntryReview(title: "Termes appris par erreur", action: "Retirer", entries: suspects) { store.delete(ids: $0) }
        }
        .sheet(isPresented: Binding(get: { scanned != nil }, set: { if !$0 { scanned = nil } })) {
            let found = scanned ?? []
            EntryReview(title: "Termes du projet", action: "Ajouter", entries: found) { chosen in
                store.add(contentsOf: found.filter { chosen.contains($0.id) })
            }
        }
        .sheet(item: $editing) { entry in
            DictionaryEditor(entry: entry) { edited in
                store.update(edited)
            }
        }
    }

    private func scanFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scanner"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Shown before anything is added (FLU-138): a folder's name can be a client's.
        scanned = ProjectVocabulary.candidates(
            folderName: url.lastPathComponent,
            packageJSON: try? Data(contentsOf: url.appendingPathComponent("package.json")),
            known: store.entries
        ).map(DictionaryEntry.term)
    }
}

// MARK: - Row

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    private let reveal = HoverActionsReveal()

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Lamp(color: DS.Color.pilot, isLit: entry.isEnabled, size: 6)

            Silkscreen(
                text: entry.kind == .correction ? "Correction" : "Terme",
                color: DS.Color.inkOnDeck.opacity(0.5)
            )
            .frame(width: 64, alignment: .leading)

            // A correction reads "heard → written"; a term is just the word.
            if entry.kind == .correction {
                Text(entry.hear)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkOnDeck.opacity(0.6))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DS.Color.inkSecondary)  // FLU-38: ≥ 3:1 (was ink at 40 %)
            }
            Text(entry.write)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.inkOnDeck)

            Spacer()

            if isHovering || reveal.withoutPointer {
                rowButton("Modifier", action: onEdit)
                rowButton(entry.isEnabled ? "Désactiver" : "Activer", action: onToggle)
                rowButton("Supprimer", action: onDelete)
            }
        }
        .opacity(entry.isEnabled ? 1 : 0.45)
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
                .fill(isHovering ? DS.Color.hover : DS.Color.panel)
                .overlay(RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline))
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: { onEdit() })
        .onHover { isHovering = $0 }
    }

    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        ChipButton(title: title, action: action)
    }
}

// MARK: - Review

/// Entries with a checkbox each (ticked), acted on by `action` only: « Revoir » the suspect
/// terms (FLU-88), the words a project scan found (FLU-138).
private struct EntryReview: View {
    let title: String
    let action: String
    let entries: [DictionaryEntry]
    let onConfirm: (Set<UUID>) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kept: Set<UUID> = []

    private var chosen: Set<UUID> { Set(entries.map(\.id)).subtracting(kept) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            Silkscreen(text: title, large: true)

            if entries.isEmpty {
                Text("Rien de nouveau").font(DS.Font.body).foregroundStyle(DS.Color.inkSecondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: DS.Space.snug) {
                    ForEach(entries) { entry in
                        Toggle(isOn: Binding(
                            get: { !kept.contains(entry.id) },
                            set: { isOn in if isOn { kept.remove(entry.id) } else { kept.insert(entry.id) } }
                        )) {
                            Text(entry.write).font(DS.Font.body).foregroundStyle(DS.Color.ink)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 280)

            HStack(spacing: DS.Space.snug) {
                Spacer()
                TransportKey(title: "Annuler") { dismiss() }
                TransportKey(title: action, isEngaged: !chosen.isEmpty, engagedColor: DS.Color.ink) {
                    guard !chosen.isEmpty else { return }
                    onConfirm(chosen)
                    dismiss()
                }
                .disabled(chosen.isEmpty)
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 360)
        .background(BrushedPanel(radius: DS.Radius.window))
    }
}

// MARK: - Editor

/// The add / edit sheet for one entry. Its warnings are recomputed on every keystroke.
private struct DictionaryEditor: View {
    let entry: DictionaryEntry?
    let onSave: (DictionaryEntry) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var kind: DictionaryEntry.Kind
    @State private var hear: String
    @State private var write: String

    init(entry: DictionaryEntry?, onSave: @escaping (DictionaryEntry) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _kind = State(initialValue: entry?.kind ?? .term)
        _hear = State(initialValue: entry?.hear ?? "")
        _write = State(initialValue: entry?.write ?? "")
    }

    /// The entry as it would be saved right now.
    private var draft: DictionaryEntry {
        let trimmedWrite = write.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedHear = hear.trimmingCharacters(in: .whitespacesAndNewlines)
        return DictionaryEntry(
            id: entry?.id ?? UUID(),
            kind: kind,
            write: trimmedWrite,
            hear: kind == .correction ? trimmedHear : "",
            isEnabled: entry?.isEnabled ?? true
        )
    }

    private var warnings: [DictionaryWarning] { DictionaryWarning.check(draft) }

    private var isValid: Bool {
        let candidate = draft
        return !candidate.write.isEmpty && (candidate.kind == .term || !candidate.hear.isEmpty)
            && DictionaryFileFormat.canStore(candidate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            Silkscreen(text: entry == nil ? "Nouvelle entrée" : "Modifier l'entrée", large: true)

            kindPicker

            VStack(alignment: .leading, spacing: DS.Space.base) {
                if kind == .correction {
                    field("Quand Fluence entend", text: $hear, prompt: "cloud code")
                }
                field(
                    kind == .correction ? "Écrire" : "Mot ou expression",
                    text: $write,
                    prompt: kind == .correction ? "Claude Code" : "Anthropic"
                )
            }

            ForEach(warnings) { warning in
                HStack(alignment: .top, spacing: DS.Space.snug) {
                    Lamp(color: DS.Color.pilot, isLit: true, size: 6)
                        .padding(.top, 3)
                    Text(warning.french)
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DS.Space.snug)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                        .strokeBorder(DS.Color.selectionEdge, lineWidth: DS.Border.hairline)
                )
            }

            // dictionary.txt would read the line back as a comment or as another correction (FLU-138).
            if !draft.write.isEmpty, !DictionaryFileFormat.canStore(draft) {
                Text("« # » au début ou « -> » ne peuvent pas être enregistrés.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.faultText)
            }

            HStack(spacing: DS.Space.snug) {
                Spacer()
                TransportKey(title: "Annuler") { dismiss() }
                TransportKey(title: "Enregistrer", isEngaged: isValid, engagedColor: DS.Color.ink) {
                    guard isValid else { return }
                    onSave(draft)
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 460)
        .background(BrushedPanel(radius: DS.Radius.window))
    }

    /// Term or correction, as two keys side by side.
    private var kindPicker: some View {
        HStack(spacing: DS.Space.snug) {
            ForEach([DictionaryEntry.Kind.term, .correction], id: \.self) { candidate in
                TransportKey(
                    title: candidate == .term ? "Terme" : "Correction",
                    isEngaged: kind == candidate,
                    engagedColor: DS.Color.ink
                ) {
                    withAnimation(DS.Motion.panel) { kind = candidate }
                }
                .background {
                    if kind == candidate {
                        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous).fill(DS.Color.selection)
                    }
                }
            }
        }
    }

    private func field(_ label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.tight) {
            Silkscreen(text: label)
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkOnDeck)
                .padding(DS.Space.snug)
                .background(DS.Color.deck, in: RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip, style: .continuous)
                        .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                )
        }
    }
}

extension DictionaryWarning {
    /// The warning in French; FluenceDictionary's `message` is the English (FLU-12).
    var french: String {
        let trigger = FrenchFormat.quoted(self.trigger)
        switch kind {
        case .ordinaryWord:
            return "\(trigger) est un mot courant. Chacune de ses occurrences sera réécrite, "
                + "pas seulement celles que vous visez. Préférez une expression plus longue."
        case .veryShort:
            return "\(trigger) est très court et se retrouvera souvent. Préférez une expression plus longue."
        case .rewritesToItself:
            return "Cette entrée remplace \(trigger) par lui-même : elle ne changera jamais rien."
        }
    }
}
