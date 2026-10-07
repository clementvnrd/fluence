import AppKit
import SwiftUI

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
                SearchField(text: $query, placeholder: "Search voice snippets")
                addButton
                    .padding(.trailing, DS.Space.base)
                    .background(DS.Color.deck)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(DS.Color.seam).frame(height: DS.Border.seam)
            }

            if entries.isEmpty {
                EmptyPanel(
                    label: store.entries.isEmpty ? "No snippets" : "No matches",
                    detail: store.entries.isEmpty
                        ? "Add spoken shortcuts that expand into full text."
                        : "Try a different search."
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
            SnippetEditor(entry: nil) { cue, expansion in
                store.add(cue: cue, expansion: expansion)
            }
        }
        .sheet(item: $editing) { entry in
            SnippetEditor(entry: entry) { cue, expansion in
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
                Silkscreen(text: "Add", color: DS.Color.inkOnDeck)
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
            Silkscreen(text: "\(store.entries.count) snippets", color: DS.Color.inkOnDeck.opacity(0.5))
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([store.fileURL])
            } label: {
                Silkscreen(text: "Reveal snippets.json", color: DS.Color.inkOnDeck.opacity(0.5))
            }
            .buttonStyle(.plain)
            .help(store.fileURL.path)
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
                text: "Cue",
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
                rowButton("Edit", action: onEdit)
                rowButton(entry.isEnabled ? "Off" : "On", action: onToggle)
                rowButton("Delete", action: onDelete)
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
    let onSave: (String, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var cue: String
    @State private var expansion: String

    init(entry: SnippetEntry?, onSave: @escaping (String, String) -> Void) {
        self.entry = entry
        self.onSave = onSave
        _cue = State(initialValue: entry?.cue ?? "")
        _expansion = State(initialValue: entry?.expansion ?? "")
    }

    private var isValid: Bool {
        !cue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !expansion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            Silkscreen(text: entry == nil ? "New Voice Snippet" : "Edit Voice Snippet", large: true)

            VStack(alignment: .leading, spacing: DS.Space.base) {
                field("Spoken Cue (e.g. 'my calendly')", text: $cue, prompt: "my calendly")

                VStack(alignment: .leading, spacing: DS.Space.tight) {
                    Silkscreen(text: "Expanded Text")
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

            HStack(spacing: DS.Space.snug) {
                Spacer()
                TransportKey(title: "Cancel") { dismiss() }
                TransportKey(title: "Save", isEngaged: isValid, engagedColor: DS.Color.ink) {
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
