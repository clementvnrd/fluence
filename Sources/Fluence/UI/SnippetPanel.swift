import AppKit
import FluenceCore
import SwiftUI

/// His panel was written against his own `SnippetEntry`; underneath it is now FluenceCore's
/// `Snippet`, stored sealed by `SnippetStore` (`snippets.sealed`).
typealias SnippetEntry = Snippet

extension Snippet {
    /// What you say: Clement's name for the trigger.
    var cue: String {
        get { trigger }
        set { trigger = newValue }
    }
}

/// Voice Snippets panel: add, edit, delete, search spoken shortcuts.
///
/// Spoken cues ("my calendly", "bug report template") automatically expand into full
/// multi-line blocks of text upon dictation.
struct SnippetPanel: View {
    @State private var store = SnippetStore.shared
    @State private var query = ""
    @State private var editing: SnippetEntry?
    @State private var isAdding = false

    private var entries: [SnippetEntry] { store.filtered(by: query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SearchField(text: $query, placeholder: "Rechercher parmi les snippets…")
                addButton
                    .padding(.trailing, DS.Space.base)
                    .background(DS.Color.deck)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(DS.Color.seam).frame(height: DS.Border.seam)
            }

            if entries.isEmpty {
                EmptyPanel(
                    label: store.entries.isEmpty ? "Aucun snippet" : "Aucun résultat",
                    detail: store.entries.isEmpty
                        ? "Ajoutez des raccourcis vocaux qui se transforment en texte complet."
                        : "Essayez une autre recherche."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.tight) {
                        ForEach(entries) { entry in
                            SnippetRow(
                                entry: entry,
                                onEdit: { editing = entry },
                                onToggle: { store.toggle(entry) },
                                onDelete: { store.delete(entry) }
                            )
                        }
                    }
                    .padding(DS.Space.base)
                }
            }

            footer
        }
        .sheet(isPresented: $isAdding) {
            SnippetEditor(entry: nil, others: store.entries) { cue, expansion in
                store.add(cue: cue, expansion: expansion)
            }
        }
        .sheet(item: $editing) { entry in
            SnippetEditor(entry: entry, others: store.entries) { cue, expansion in
                var updated = entry
                updated.cue = cue
                updated.expansion = expansion
                store.update(updated)
            }
        }
    }

    private var addButton: some View {
        Button { isAdding = true } label: {
            HStack(spacing: DS.Space.tight) {
                Image(systemName: "plus")
                    .font(.system(size: 9, weight: .bold))
                Silkscreen(text: "Ajouter", color: DS.Color.inkOnDeck)
            }
            .foregroundStyle(DS.Color.inkOnDeck)
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.snug)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip)
                    .strokeBorder(DS.Color.inkOnDeck.opacity(0.35), lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.snug) {
            Silkscreen(text: "\(store.entries.count) snippet\(store.entries.count == 1 ? "" : "s")", color: DS.Color.inkOnDeck.opacity(0.5))
            Spacer()
            // The file is sealed, so there is nothing to reveal; a fault is said here instead.
            if let problem = store.problem {
                Text(problem)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.fault)
                    .lineLimit(2)
            } else {
                Silkscreen(text: "Chiffrés sur ce Mac", color: DS.Color.inkOnDeck.opacity(0.5))
            }
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(DS.Color.deck)
        .overlay(alignment: .top) {
            Rectangle().fill(DS.Color.seam).frame(height: DS.Border.seam)
        }
    }
}

// MARK: - Row

private struct SnippetRow: View {
    let entry: SnippetEntry
    let onEdit: () -> Void
    let onToggle: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: DS.Space.base) {
            Lamp(color: DS.Color.silkscreen, isLit: entry.isEnabled, size: 6)

            Silkscreen(
                text: "Dire",
                color: DS.Color.inkOnDeck.opacity(0.5)
            )
            .frame(width: 32, alignment: .leading)

            Text("\"\(entry.cue)\"")
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.inkOnDeck)

            Image(systemName: "arrow.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(DS.Color.inkOnDeck.opacity(0.4))

            Text(entry.expansion.replacingOccurrences(of: "\n", with: " ⏎ "))
                .font(DS.Font.body)
                .foregroundStyle(DS.Color.inkOnDeck.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer()

            if isHovering {
                rowButton("Modifier", action: onEdit)
                rowButton(entry.isEnabled ? "Désactiver" : "Activer", action: onToggle)
                rowButton("Supprimer", action: onDelete)
            }
        }
        .opacity(entry.isEnabled ? 1 : 0.45)
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(isHovering ? DS.Color.hover : DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
        .onHover { isHovering = $0 }
    }

    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Silkscreen(text: title, color: DS.Color.inkOnDeck.opacity(0.6))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Editor

private struct SnippetEditor: View {
    let entry: SnippetEntry?
    let others: [SnippetEntry]
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cue: String
    @State private var expansion: String

    init(entry: SnippetEntry?, others: [SnippetEntry], onSave: @escaping (String, String) -> Void) {
        self.entry = entry
        self.others = others
        self.onSave = onSave
        _cue = State(initialValue: entry?.cue ?? "")
        _expansion = State(initialValue: entry?.expansion ?? "")
    }

    /// FluenceCore's rules: one-breath trigger, bounded text, no duplicate trigger.
    private var problem: String? {
        Snippet(id: entry?.id ?? UUID(), trigger: cue, expansion: expansion).problem(among: others)
    }

    private var isValid: Bool { problem == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            Silkscreen(text: entry == nil ? "Nouveau snippet vocal" : "Modifier le snippet vocal", large: true)

            VStack(alignment: .leading, spacing: DS.Space.base) {
                field("Phrase prononcée (ex. « mon calendly »)", text: $cue, prompt: "mon calendly")

                VStack(alignment: .leading, spacing: DS.Space.tight) {
                    Silkscreen(text: "Texte inséré")
                    TextEditor(text: $expansion)
                        .font(DS.Font.body)
                        .foregroundStyle(DS.Color.inkOnDeck)
                        .frame(minHeight: 110)
                        .padding(DS.Space.snug)
                        .scrollContentBackground(.hidden)
                        .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
                        .overlay(
                            RoundedRectangle(cornerRadius: DS.Radius.chip)
                                .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                        )
                }
            }

            if let problem, !cue.isEmpty || !expansion.isEmpty {
                Text(problem)
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }

            HStack(spacing: DS.Space.snug) {
                Spacer()
                TransportKey(title: "Annuler") { dismiss() }
                TransportKey(title: "Enregistrer", isEngaged: isValid, engagedColor: DS.Color.ink) {
                    guard isValid else { return }
                    onSave(
                        cue.trimmingCharacters(in: .whitespacesAndNewlines),
                        expansion.trimmingCharacters(in: .whitespacesAndNewlines)
                    )
                    dismiss()
                }
                .disabled(!isValid)
            }
        }
        .padding(DS.Space.panel)
        .frame(width: 480)
        .background(BrushedPanel(radius: DS.Radius.window))
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
