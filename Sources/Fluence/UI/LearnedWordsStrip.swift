import FluenceCore
import SwiftUI

/// "Ajouter « Claude » au dictionnaire ?" — the auto-learn proposals (FLU-5), one line each,
/// above the main window's content. Quiet on purpose: it appears only when there is
/// something to decide, and nothing happens until the user presses Ajouter. The newest is
/// also offered on the HUD capsule for a moment (FLU-12).
struct LearnedWordsStrip: View {
    @State private var learned = LearnedWords.shared

    var body: some View {
        if !learned.proposals.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.snug) {
                ForEach(learned.proposals) { proposal in
                    row(proposal)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(DS.Color.selection.opacity(0.5))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(DS.Color.selectionEdge.opacity(0.5), lineWidth: 1))
            )
        }
    }

    private func row(_ proposal: EditLearner.Proposal) -> some View {
        HStack(spacing: DS.Space.snug) {
            Image(systemName: "book.closed").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.Color.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text("Ajouter \(FrenchFormat.quoted(proposal.written)) au dictionnaire ?")
                    .font(DS.Font.label)
                    .foregroundStyle(DS.Color.ink)
                    .lineLimit(1)
                if proposal.isCorrection {
                    Text("Vous avez corrigé \(FrenchFormat.quoted(proposal.heard))")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.inkSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: DS.Space.snug)
            CapButton(title: "Ignorer", height: 24) { learned.dismiss(proposal) }
            PrimaryButton(title: "Ajouter", height: 24) { learned.accept(proposal) }
        }
    }
}
