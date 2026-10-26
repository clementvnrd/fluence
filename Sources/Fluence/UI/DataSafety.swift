import AppKit
import FluenceCore
import Foundation
import Observation
import SwiftUI
import UniformTypeIdentifiers

/// The state behind Réglages ▸ Confidentialité's data-safety rows (FLU-36): whether the
/// encryption key is lost, the encrypted backup, its restore, and the fresh start.
@MainActor
@Observable
final class DataSafetyModel {
    static let shared = DataSafetyModel()

    /// Sealed data is on disk and no key here opens it.
    private(set) var isKeyLost = Vault.isKeyLost
    /// An action is running; its buttons are off.
    private(set) var isBusy = false
    /// The outcome of the last action, under the backup rows.
    private(set) var note: Note?
    /// A file was chosen; the passphrase sheet is up for it.
    var pending: PendingAction?

    struct Note: Equatable {
        let text: String
        let isFault: Bool
    }

    struct PendingAction: Identifiable {
        let id = UUID()
        let url: URL
        let isBackup: Bool
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
            Diagnostics.error("vault.freshStart", error)
            note = Note(text: "Impossible de repartir de zéro : \(Self.describe(error))", isFault: true)
        }
    }

    // MARK: Sauvegarder / Restaurer

    private static var backupType: UTType {
        UTType(filenameExtension: DataBackup.fileExtension, conformingTo: .data) ?? .data
    }

    /// Where to write the backup; the passphrase sheet follows.
    func chooseBackupDestination() {
        let panel = NSSavePanel()
        panel.title = "Sauvegarder mes données"
        panel.prompt = "Enregistrer"
        let day = Date().formatted(.iso8601.year().month().day())
        panel.nameFieldStringValue = "Fluence \(day).\(DataBackup.fileExtension)"
        panel.allowedContentTypes = [Self.backupType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pending = PendingAction(url: url, isBackup: true)
    }

    /// Which backup to restore; the passphrase sheet follows.
    func chooseBackupToRestore() {
        let panel = NSOpenPanel()
        panel.title = "Restaurer une sauvegarde"
        panel.prompt = "Restaurer"
        panel.allowedContentTypes = [Self.backupType]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pending = PendingAction(url: url, isBackup: false)
    }

    /// Both run on the history's queue, so no dictation is appended halfway through.
    func run(_ action: PendingAction, passphrase: String) {
        guard !isBusy else { return }
        isBusy = true
        note = nil
        let url = action.url
        if action.isBackup {
            HistoryFile.shared.exclusively {
                let result = Result { try Self.writeBackup(to: url, passphrase: passphrase) }
                Task { @MainActor in DataSafetyModel.shared.finishBackup(result) }
            }
        } else {
            HistoryFile.shared.exclusively {
                let result = Result {
                    let contents = try DataBackup.open(try Data(contentsOf: url), passphrase: passphrase)
                    return try DataRestore.restore(contents, keyring: Vault.keyring)
                }
                Task { @MainActor in DataSafetyModel.shared.finishRestore(result) }
            }
        }
    }

    /// Refused while the key is lost: a backup of data nothing can open helps nobody.
    private nonisolated static func writeBackup(to url: URL, passphrase: String) throws -> Int {
        let key = try Vault.masterKey()
        let files = try DataBackup.collect(from: Vault.keyring.layout)
        let contents = DataBackup.Contents(createdAt: Date(), masterKey: key.withUnsafeBytes { Data($0) }, files: files)
        let archive = try DataBackup.seal(contents, passphrase: passphrase)
        try archive.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return archive.count
    }

    private func finishBackup(_ result: Result<Int, Error>) {
        isBusy = false
        switch result {
        case .success(let bytes):
            Log.app.info("backup written: \(bytes, privacy: .public) bytes")
            note = Note(text: "Sauvegarde enregistrée.", isFault: false)
        case .failure(let error):
            Log.app.error("backup failed — \(String(describing: error), privacy: .public)")
            Diagnostics.error("backup.write", error)
            note = Note(text: "Sauvegarde impossible : \(Self.describe(error))", isFault: true)
        }
    }

    private func finishRestore(_ result: Result<DataRestore.Summary, Error>) {
        isBusy = false
        isKeyLost = Vault.isKeyLost
        switch result {
        case .success(let summary):
            Log.app.info("restore: \(summary.dictations, privacy: .public) dictations, \(summary.snippets, privacy: .public) snippets, \(summary.dictionaryLines, privacy: .public) dictionary lines, \(summary.meetings, privacy: .public) meetings; key adopted \(summary.adoptedKey, privacy: .public), set aside \(summary.setAside != nil, privacy: .public)")
            note = Note(text: Self.describe(summary), isFault: !summary.skipped.isEmpty)
            Self.reloadStores()
        case .failure(let error):
            Log.app.error("restore failed — \(String(describing: error), privacy: .public)")
            Diagnostics.error("backup.restore", error)
            note = Note(text: "Restauration impossible : \(Self.describe(error))", isFault: true)
        }
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? Vault.Failure { return failure.description }
        return error.localizedDescription
    }

    /// « Restauré : 120 dictées, 4 snippets, 3 réunions. »
    static func describe(_ summary: DataRestore.Summary) -> String {
        func count(_ n: Int, _ one: String, _ many: String) -> String? {
            n == 0 ? nil : "\(n) \(n == 1 ? one : many)"
        }
        let parts = [
            count(summary.dictations, "dictée", "dictées"),
            count(summary.snippets, "snippet", "snippets"),
            count(summary.dictionaryLines, "entrée du dictionnaire", "entrées du dictionnaire"),
            count(summary.meetings, "réunion", "réunions"),
        ].compactMap { $0 }
        var text = parts.isEmpty ? "Rien à ajouter : tout est déjà sur ce Mac." : "Restauré : " + parts.joined(separator: ", ") + "."
        if summary.setAside != nil { text += " Les données illisibles sont mises de côté." }
        for skipped in summary.skipped { text += " " + skipped }
        return text
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
                HStack(spacing: DS.Space.snug) {
                    CapButton(title: "Restaurer…", height: 28, isEnabled: !model.isBusy) { model.chooseBackupToRestore() }
                    DestructiveButton(title: "Repartir de zéro…", systemImage: "arrow.counterclockwise", isEnabled: !model.isBusy) {
                        isConfirmingFreshStart = true
                    }
                }
            }
            RowNote(text: "Vos données chiffrées ne peuvent plus être lues sur ce Mac.", color: DS.Color.faultText)
        }
        .confirmationDialog("Repartir de zéro ?", isPresented: $isConfirmingFreshStart, titleVisibility: .visible) {
            Button("Repartir de zéro", role: .destructive) { model.startFresh() }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("L'historique, les snippets, les réunions et les empreintes vocales illisibles sont déplacés dans un dossier « Données illisibles », pas effacés. Le dictionnaire et les réglages restent.")
        }
    }
}

/// « Sauvegarder mes données » and « Restaurer une sauvegarde », in Confidentialité.
struct BackupCard: View {
    @Bindable var model: DataSafetyModel

    var body: some View {
        SectionCard {
            SettingsRow(
                systemImage: "externaldrive.badge.checkmark",
                title: "Sauvegarder mes données",
                info: "Un seul fichier, protégé par une phrase secrète : historique, snippets, dictionnaire et réunions (sans l'audio ni les empreintes vocales). Pour tout retrouver sur un autre Mac, ou après une réinitialisation du trousseau."
            ) {
                CapButton(title: "Sauvegarder…", height: 24, isEnabled: !model.isBusy && !model.isKeyLost) {
                    model.chooseBackupDestination()
                }
            }
            RowDivider()
            SettingsRow(
                systemImage: "arrow.down.doc",
                title: "Restaurer une sauvegarde",
                info: "Ajoute le contenu d'une sauvegarde à ce Mac. Rien n'est remplacé ni effacé."
            ) {
                CapButton(title: "Restaurer…", height: 24, isEnabled: !model.isBusy) {
                    model.chooseBackupToRestore()
                }
            }
            if model.isBusy {
                RowNote(text: "En cours…")
            } else if let note = model.note {
                RowNote(text: note.text, color: note.isFault ? DS.Color.faultText : DS.Color.inkSecondary)
            }
        }
        .sheet(item: $model.pending) { action in
            PassphraseSheet(isBackup: action.isBackup) { model.run(action, passphrase: $0) }
        }
    }
}

/// The passphrase of a backup: twice to make one, once to open one.
struct PassphraseSheet: View {
    let isBackup: Bool
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var confirmation = ""

    private var problem: String? {
        if !passphrase.isEmpty, passphrase.count < DataBackup.minimumPassphraseLength {
            return "Au moins \(DataBackup.minimumPassphraseLength) caractères."
        }
        if isBackup, !confirmation.isEmpty, confirmation != passphrase { return "Les deux phrases diffèrent." }
        return nil
    }

    private var isValid: Bool {
        passphrase.count >= DataBackup.minimumPassphraseLength && (!isBackup || confirmation == passphrase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.base) {
            Text(isBackup ? "Sauvegarder mes données" : "Restaurer une sauvegarde")
                .font(DS.Font.title)
                .foregroundStyle(DS.Color.ink)
            SecureField("Phrase secrète", text: $passphrase)
                .textFieldStyle(.roundedBorder)
            if isBackup {
                SecureField("Confirmer la phrase secrète", text: $confirmation)
                    .textFieldStyle(.roundedBorder)
                // The one thing not to miss: there is no way back without it.
                Text("Sans cette phrase, la sauvegarde ne peut pas être ouverte.")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.inkSecondary)
            }
            if let problem {
                Text(problem).font(DS.Font.caption).foregroundStyle(DS.Color.faultText)
            }
            HStack {
                Spacer()
                CapButton(title: "Annuler") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                PrimaryButton(title: isBackup ? "Sauvegarder" : "Restaurer", isEnabled: isValid) {
                    onConfirm(passphrase)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.Space.wide)
        .frame(width: 380)
    }
}
