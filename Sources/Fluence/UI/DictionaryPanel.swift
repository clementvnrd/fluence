import AppKit
import FluenceCore
import FluenceDictionary
import SwiftUI

/// Dictionnaire (FLU-12): the words Fluence must write right — add, edit, delete, search.
///
/// Both entry kinds live in one list rather than separate tabs — they're two shapes of the
/// same idea and you want to see everything you've taught it at once. The kind is carried by
/// a tag on each row.
struct DictionaryPanel: View {
    /// What the « Lexique Tech » button just did, shown on it for a moment (FLU-17).
    @State private var lexiconResult: String?
    @State private var store = DictionaryStore.shared
    @State private var query = ""
    @State private var editing: DictionaryEntry?
    @State private var isAdding = false

    private var entries: [DictionaryEntry] { store.filtered(by: query) }

    /// Adds the tech lexicon's missing terms and says how many; reads « à jour » once there
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
            lexiconResult = added == 0 ? "Déjà à jour" : "+ " + FrenchFormat.count(added, "terme ajouté", "termes ajoutés")
            Task {
                try? await Task.sleep(for: .seconds(2.5))
                lexiconResult = nil
            }
        }
        .help(missing == 0
            ? "Tous les termes techniques, Git et anglicismes du lexique sont déjà dans votre dictionnaire."
            : "Ajouter \(FrenchFormat.count(missing, "terme")) techniques, Git et anglicismes à votre dictionnaire.")
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(
                title: "Dictionnaire",
                subtitle: FrenchFormat.count(store.entries.count, "entrée")
            ) {
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
                                    var updated = entry
                                    updated.isEnabled.toggle()
                                    store.update(updated)
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
            DictionaryEditor(entry: nil) { store.add($0) }
        }
        .sheet(item: $editing) { entry in
            DictionaryEditor(entry: entry) { store.update($0) }
        }
    }

    private func scanFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Scanner"
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                _ = await AutoLearningEngine.shared.scanWorkspaceForVocabulary(at: url)
            }
        }
    }
}

// MARK: - Row

private struct DictionaryRow: View {
    let entry: DictionaryEntry
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Lamp(color: DS.Color.pilot, isLit: entry.isEnabled, size: 6)

            Silkscreen(
                text: entry.kind == .correction ? "Correction" : "Terme",
                color: DS.Color.inkOnDeck.opacity(0.5)
            )
            .frame(width: 64, alignment: .leading)

            if entry.kind == .correction {
                Text(entry.hear)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkOnDeck.opacity(0.6))
                Image(systemName: "arrow.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DS.Color.inkOnDeck.opacity(0.4))
            }

            Text(entry.write)
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.inkOnDeck)

            Spacer()

            if isHovering {
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

// MARK: - Editor

/// Add or edit one entry, with the false-positive warning shown live as you type.
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

    private var draft: DictionaryEntry {
        DictionaryEntry(
            id: entry?.id ?? UUID(),
            kind: kind,
            write: write.trimmingCharacters(in: .whitespacesAndNewlines),
            hear: kind == .correction ? hear.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            isEnabled: entry?.isEnabled ?? true
        )
    }

    private var warnings: [DictionaryWarning] { DictionaryWarning.check(draft) }

    private var isValid: Bool {
        !draft.write.isEmpty && (kind == .term || !draft.hear.isEmpty)
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
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
                        .strokeBorder(DS.Color.selectionEdge, lineWidth: DS.Border.hairline)
                )
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
                        RoundedRectangle(cornerRadius: DS.Radius.control).fill(DS.Color.selection)
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
                .padding(.horizontal, DS.Space.snug)
                .padding(.vertical, DS.Space.snug)
                .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.Radius.chip)
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
            return "\(trigger) est un mot courant (en anglais). Chacune de ses occurrences sera réécrite, "
                + "pas seulement celles que vous visez. Préférez une expression plus longue."
        case .veryShort:
            return "\(trigger) est très court et se retrouvera souvent. Préférez une expression plus longue."
        case .rewritesToItself:
            return "Cette entrée remplace \(trigger) par lui-même : elle ne changera jamais rien."
        }
    }
}
