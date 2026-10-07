import FluenceCore
import SwiftUI

/// "Add 'Claude' to the dictionary?" — the auto-learn proposals (FLU-5), one line each,
/// above the main window's well. Quiet on purpose: it appears only when there is something
/// to decide, and nothing happens until the user presses Add.
struct LearnedWordsStrip: View {
    @State private var learned = LearnedWords.shared

    var body: some View {
        if !learned.proposals.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.tight) {
                ForEach(learned.proposals) { proposal in
                    row(proposal)
                }
            }
            .padding(.horizontal, DS.Space.base)
            .padding(.vertical, DS.Space.snug)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BrushedPanel())
        }
    }

    private func row(_ proposal: EditLearner.Proposal) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Space.snug) {
            Lamp(color: DS.Color.pilot, isLit: true, size: DS.Library.lampSmall)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - DS.Library.lampBaselineNudge }
            Silkscreen(text: "Learned")
            Text(description(proposal))
                .font(DS.Font.label)
                .foregroundStyle(DS.Color.ink)
                .lineLimit(1)
            Spacer(minLength: DS.Space.snug)
            TransportKey(title: "Add", engagedColor: DS.Color.ink) { learned.accept(proposal) }
            TransportKey(title: "Dismiss") { learned.dismiss(proposal) }
        }
    }

    private func description(_ proposal: EditLearner.Proposal) -> String {
        proposal.isCorrection
            ? "You corrected “\(proposal.heard)” to “\(proposal.written)”. Add it to the dictionary?"
            : "Add “\(proposal.written)” to the dictionary?"
    }
}
