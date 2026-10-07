import FluenceCore
import SwiftUI

/// Snippets (FLU-5): add, edit, delete, search. Laid out like the dictionary — a search
/// strip, a list of rows on the deck, an editor sheet — because they are two halves of
/// "teach Fluence your words".
struct SnippetsPanel: View {
    @State private var store = SnippetStore.shared
    @State private var query = ""
    @State private var editing: Snippet?
    @State private var isAdding = false

    private var snippets: [Snippet] { store.filtered(by: query) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                SearchField(text: $query, placeholder: "Search snippets")
                addButton
                    .padding(.trailing, DS.Space.base)
                    .background(DS.Color.deck)
            }
            .overlay(alignment: .bottom) {
                Rectangle().fill(DS.Color.seam).frame(height: DS.Border.seam)
            }

            if let problem = store.problem {
                ProblemBanner(message: problem)
                    .padding(DS.Space.snug)
                    .background(DS.Color.deck)
            }

            if snippets.isEmpty {
                EmptyPanel(
                    label: store.snippets.isEmpty ? "No snippets" : "No matches",
                    detail: store.snippets.isEmpty
                        ? "Say a short phrase, get a longer text: an address, a link, a signature."
                        : "Try a different search."
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: DS.Space.tight) {
                        ForEach(snippets) { snippet in
                            SnippetRow(
                                snippet: snippet,
                                onEdit: { editing = snippet },
                                onDelete: { store.delete(snippet) }
                            )
                        }
                    }
                    .padding(DS.Space.base)
                }
            }

            footer
        }
        .sheet(isPresented: $isAdding) {
            SnippetEditor(snippet: nil, others: store.snippets) { store.add($0) }
        }
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet, others: store.snippets) { store.update($0) }
        }
    }

    private var addButton: some View {
        Button { isAdding = true } label: {
            HStack(spacing: DS.Space.tight) {
                Image(systemName: "plus")
                    .font(.system(size: DS.Parity.glyph, weight: .bold))
                Silkscreen(text: "Add", color: DS.Color.inkOnDeck)
            }
            .foregroundStyle(DS.Color.inkOnDeck)
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.snug)
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.chip)
                    .strokeBorder(DS.Color.inkOnDeck.opacity(DS.Parity.edgeFaint), lineWidth: DS.Border.hairline)
            )
        }
        .buttonStyle(.plain)
        .keyboardShortcut("n", modifiers: .command)
    }

    private var footer: some View {
        HStack(spacing: DS.Space.snug) {
            Silkscreen(
                text: "\(store.snippets.count) snippet\(store.snippets.count == 1 ? "" : "s")",
                color: DS.Color.inkOnDeck.opacity(DS.Parity.inkFaint)
            )
            Spacer()
            Silkscreen(text: "Encrypted on this Mac", color: DS.Color.inkOnDeck.opacity(DS.Parity.inkFaint))
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
    let snippet: Snippet
    let onEdit: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.base) {
            Silkscreen(text: "Say", color: DS.Color.inkOnDeck.opacity(DS.Parity.inkFaint))
                .frame(width: DS.Parity.tagColumn, alignment: .leading)

            VStack(alignment: .leading, spacing: DS.Space.hair) {
                Text(snippet.trigger)
                    .font(DS.Font.bodyEmphasis)
                    .foregroundStyle(DS.Color.inkOnDeck)
                Text(snippet.expansion)
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkOnDeck.opacity(DS.Parity.inkDim))
                    .lineLimit(DS.Parity.previewLines)
                    .truncationMode(.tail)
            }

            Spacer()

            if isHovering {
                rowButton("Edit", action: onEdit)
                rowButton("Delete", action: onDelete)
            }
        }
        .padding(.horizontal, DS.Space.base)
        .padding(.vertical, DS.Space.snug)
        .background(isHovering ? DS.Color.hover : DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
        .onHover { isHovering = $0 }
    }

    private func rowButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Silkscreen(text: title, color: DS.Color.inkOnDeck.opacity(DS.Parity.inkDim))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Editor

private struct SnippetEditor: View {
    let snippet: Snippet?
    let others: [Snippet]
    let onSave: (Snippet) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var trigger: String
    @State private var expansion: String

    init(snippet: Snippet?, others: [Snippet], onSave: @escaping (Snippet) -> Void) {
        self.snippet = snippet
        self.others = others
        self.onSave = onSave
        _trigger = State(initialValue: snippet?.trigger ?? "")
        _expansion = State(initialValue: snippet?.expansion ?? "")
    }

    private var draft: Snippet {
        Snippet(
            id: snippet?.id ?? UUID(),
            trigger: trigger.trimmingCharacters(in: .whitespacesAndNewlines),
            expansion: expansion
        )
    }

    private var problem: String? { draft.problem(among: others) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.roomy) {
            Silkscreen(text: snippet == nil ? "New snippet" : "Edit snippet", large: true)

            VStack(alignment: .leading, spacing: DS.Space.tight) {
                HStack {
                    Silkscreen(text: "When you say")
                    Spacer()
                    Silkscreen(text: "\(trigger.count)/\(Snippet.triggerLimit)")
                }
                TextField("my address", text: $trigger)
                    .textFieldStyle(.plain)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkOnDeck)
                    .padding(DS.Space.snug)
                    .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.chip)
                            .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                    )
            }

            VStack(alignment: .leading, spacing: DS.Space.tight) {
                HStack {
                    Silkscreen(text: "Type exactly")
                    Spacer()
                    Silkscreen(text: "\(expansion.count)/\(Snippet.expansionLimit)")
                }
                TextEditor(text: $expansion)
                    .font(DS.Font.body)
                    .foregroundStyle(DS.Color.inkOnDeck)
                    .scrollContentBackground(.hidden)
                    .padding(DS.Space.tight)
                    .frame(minHeight: DS.Parity.editorMinHeight)
                    .background(DS.Color.deck, in: .rect(cornerRadius: DS.Radius.chip))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.chip)
                            .strokeBorder(DS.Color.seam, lineWidth: DS.Border.hairline)
                    )
            }

            Text("Said on its own, or inside a sentence. The text is typed as written here — "
                + "cleanup, style and the dictionary leave it alone.")
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let problem, !trigger.isEmpty || !expansion.isEmpty {
                HStack(alignment: .top, spacing: DS.Space.snug) {
                    Lamp(color: DS.Color.pilot, isLit: true, size: DS.Library.lampSmall)
                        .padding(.top, DS.Library.lampBaselineNudge)
                    Text(problem)
                        .font(DS.Font.label)
                        .foregroundStyle(DS.Color.ink)
                }
            }

            HStack(spacing: DS.Space.snug) {
                Spacer()
                TransportKey(title: "Cancel") { dismiss() }
                TransportKey(title: "Save", isEngaged: problem == nil, engagedColor: DS.Color.ink) {
                    guard problem == nil else { return }
                    onSave(draft)
                    dismiss()
                }
                .disabled(problem != nil)
            }
        }
        .padding(DS.Space.panel)
        .frame(width: DS.Parity.sheetWidth)
        .background(BrushedPanel(radius: DS.Radius.window))
    }
}
