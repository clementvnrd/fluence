import AppKit
import MurmurDictionary
import SwiftUI

/// Fenêtre flottante élégante pour corriger rapidement la dernière dictée
/// et apprendre automatiquement les nouveaux mots ou corrections dans le dictionnaire.
struct CorrectionQuickSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var originalText: String
    @State private var editedText: String
    @State private var learnedEntries: [DictionaryEntry] = []
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
                    Text("Modifiez le texte : les mots corrigés seront automatiquement mémorisés.")
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

            // Live detected corrections badge
            if !detectedCorrections.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 10))
                            .foregroundStyle(DS.Color.meterAmber)
                        Text("Règles qui seront ajoutées au dictionnaire :")
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.inkSecondary)
                    }

                    HStack(spacing: 8) {
                        ForEach(detectedCorrections, id: \.hear) { pair in
                            HStack(spacing: 5) {
                                Text(pair.hear)
                                    .strikethrough()
                                    .foregroundStyle(DS.Color.inkSecondary)
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 8))
                                    .foregroundStyle(DS.Color.inkSecondary)
                                Text(pair.write)
                                    .bold()
                                    .foregroundStyle(DS.Color.accent)
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(DS.Color.meterAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
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
                .disabled(editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480, height: 320)
        .background(DS.Color.chassis)
    }

    private var detectedCorrections: [AutoLearningEngine.LearnedPair] {
        guard editedText != originalText else { return [] }
        // Simple word-level scan for live preview
        let origWords = originalText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }
        let editWords = editedText.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }

        var pairs: [AutoLearningEngine.LearnedPair] = []
        let minCount = min(origWords.count, editWords.count)
        for i in 0..<minCount {
            let o = origWords[i].trimmingCharacters(in: CharacterSet.punctuationCharacters)
            let e = editWords[i].trimmingCharacters(in: CharacterSet.punctuationCharacters)
            if o.caseInsensitiveCompare(e) != .orderedSame && !o.isEmpty && !e.isEmpty {
                pairs.append(AutoLearningEngine.LearnedPair(hear: o, write: e))
            }
        }
        return pairs
    }

    private func saveAndLearn() {
        _ = AutoLearningEngine.shared.learnCorrection(from: originalText, to: editedText)
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
