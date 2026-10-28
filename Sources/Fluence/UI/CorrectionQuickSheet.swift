import AppKit
import FluenceCore
import FluenceDictionary
import SwiftUI

/// Fenêtre flottante pour corriger la dernière dictée et ajouter au dictionnaire les noms
/// corrigés, cochés un par un (FLU-89).
struct CorrectionQuickSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var originalText: String
    @State private var editedText: String
    /// Proposals the user unticked; everything else listed is saved.
    @State private var unchecked: Set<EditLearner.Proposal.ID> = []
    @State private var hasSaved = false

    init(initialText: String? = nil) {
        let text = initialText ?? AutoLearningEngine.shared.lastInjectedText
        _originalText = State(initialValue: text)
        _editedText = State(initialValue: text)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack(spacing: 10) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DS.Color.accent)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Apprentissage & Correction")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(DS.Color.ink)
                    Text("Corrigez les noms mal écrits.")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                }

                Spacer()
            }

            // Editor Box
            VStack(alignment: .leading, spacing: 8) {
                Text("Texte de la dictée :")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.inkSecondary)

                TextEditor(text: $editedText)
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(DS.Color.ink)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(height: 110)
                    .background(DS.Color.well, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(DS.Color.seam, lineWidth: 1)
                    )
            }

            // FLU-89: what will be saved, each with a checkbox. The same list is saved, and it
            // comes from EditLearner, so fixing « est » → « et » no longer rewrites every « est ».
            if !proposals.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("À ajouter au dictionnaire :")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                    ForEach(proposals) { proposal in
                        Toggle(isOn: Binding(
                            get: { !unchecked.contains(proposal.id) },
                            set: { isOn in if isOn { unchecked.remove(proposal.id) } else { unchecked.insert(proposal.id) } }
                        )) {
                            Text(proposal.isCorrection ? "\(proposal.heard) → \(proposal.written)" : proposal.written)
                                .font(DS.Font.label)
                                .foregroundStyle(DS.Color.ink)
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer()

            // Footer Actions
            HStack {
                Button("Annuler") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(.plain)
                .foregroundStyle(DS.Color.inkSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                Spacer()

                Button {
                    saveAndLearn()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: hasSaved ? "checkmark" : "plus.circle.fill")
                        Text(hasSaved ? "Mémorisé !" : "Enregistrer & Mémoriser")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(DS.Color.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.plain)
                .disabled(chosen.isEmpty && !hasSaved)
            }
        }
        .padding(20)
        .frame(width: 480)
        .frame(minHeight: 320)
        .background(DS.Color.chassis)
    }

    /// EditLearner's proposals for the edit, minus spellings the dictionary already has.
    private var proposals: [EditLearner.Proposal] {
        let known = Set(DictionaryStore.shared.entries.map { $0.write.lowercased() })
        return EditLearner.proposals(inserted: originalText, edited: editedText)
            .filter { !known.contains($0.written.lowercased()) }
    }

    private var chosen: [EditLearner.Proposal] { proposals.filter { !unchecked.contains($0.id) } }

    private func saveAndLearn() {
        for proposal in chosen { LearnedWords.shared.accept(proposal) }
        hasSaved = true
        NSSound(named: "Glass")?.play()

        // The corrected text is not typed anywhere: with this sheet in front, "the active
        // app" is Fluence itself, and the paste would land in the sheet's own editor (FLU-11).
        Task {
            try? await Task.sleep(for: .seconds(0.8))
            dismiss()
        }
    }
}
