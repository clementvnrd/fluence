import FluenceCore
import Foundation
import Observation
import SwiftUI

/// The state behind Réglages ▸ Confidentialité's data-safety rows (FLU-36): whether the
/// encryption key is lost, and the actions that leave that state.
@MainActor
@Observable
final class DataSafetyModel {
    static let shared = DataSafetyModel()

    /// Sealed data is on disk and no key here opens it.
    private(set) var isKeyLost = Vault.isKeyLost
    /// An action is running; its buttons are off.
    private(set) var isBusy = false
    /// The outcome of the last action, under its row.
    private(set) var note: Note?

    struct Note: Equatable {
        let text: String
        let isFault: Bool
    }

    private init() {}

    /// Asks the Vault (on the history's queue: it may read the Keychain).
    func refresh() {
        HistoryFile.shared.exclusively {
            _ = try? Vault.masterKey()
            let lost = Vault.isKeyLost
            Task { @MainActor in DataSafetyModel.shared.isKeyLost = lost }
        }
    }

    // MARK: Repartir de zéro

    /// Moves the unreadable files aside (kept, not deleted) and lets Fluence save again.
    func startFresh() {
        guard !isBusy else { return }
        isBusy = true
        note = nil
        HistoryFile.shared.exclusively {
            let result = Result { try Vault.keyring.startFresh() }
            Task { @MainActor in DataSafetyModel.shared.finishStartFresh(result) }
        }
    }

    private func finishStartFresh(_ result: Result<URL?, Error>) {
        isBusy = false
        isKeyLost = Vault.isKeyLost
        switch result {
        case .success:
            Log.app.info("vault: unreadable data set aside, new start")
            note = Note(text: "Les données illisibles sont mises de côté dans le dossier de Fluence.", isFault: false)
            Self.reloadStores()
        case .failure(let error):
            Log.app.error("vault: fresh start failed — \(String(describing: error), privacy: .public)")
            note = Note(text: "Impossible de repartir de zéro : \(error.localizedDescription)", isFault: true)
        }
    }

    /// Every store reads its file again: the key or the files changed under it.
    static func reloadStores() {
        RunLog.reload()
        SnippetStore.shared.reload()
        MeetingStore.shared.reload()
    }
}

/// Shown at the top of Confidentialité while the key is lost: the one sentence the user must
/// not miss, and the ways out.
struct KeyLostCard: View {
    @Bindable var model: DataSafetyModel
    @State private var isConfirmingFreshStart = false

    var body: some View {
        SectionCard(highlighted: true) {
            SettingsRow(
                systemImage: "lock.trianglebadge.exclamationmark",
                title: "Données illisibles",
                info: "La clé qui protège vos données n'est plus dans le trousseau de ce Mac (nouveau Mac, trousseau réinitialisé). Fluence n'en crée pas une nouvelle par-dessus : restaurez une sauvegarde pour tout retrouver, ou repartez de zéro.",
                iconTint: DS.Color.fault
            ) {
                DestructiveButton(title: "Repartir de zéro…", systemImage: "arrow.counterclockwise", isEnabled: !model.isBusy) {
                    isConfirmingFreshStart = true
                }
            }
            RowNote(text: "Vos données chiffrées ne peuvent plus être lues sur ce Mac.", color: DS.Color.fault)
        }
        .confirmationDialog("Repartir de zéro ?", isPresented: $isConfirmingFreshStart, titleVisibility: .visible) {
            Button("Repartir de zéro", role: .destructive) { model.startFresh() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("L'historique, les snippets, les réunions et les empreintes vocales illisibles sont déplacés dans un dossier « Données illisibles », pas effacés. Le dictionnaire et les réglages restent.")
        }
    }
}
