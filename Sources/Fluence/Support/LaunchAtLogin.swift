import Foundation
import Observation
import ServiceManagement

/// « Lancer Fluence au démarrage du Mac » (FLU-58): Fluence as a login item.
///
/// The system is the only source of truth, not a setting of ours: the user can also add or remove
/// Fluence in System Settings › General › Login Items, so the state is read back from
/// `SMAppService` every time it is shown.
@MainActor
@Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    private(set) var status: SMAppService.Status
    /// What the last change attempt said, in a sentence the user can read; nil when it worked.
    private(set) var problem: String?

    private init() {
        status = SMAppService.mainApp.status
    }

    /// On, or registered but waiting for the user's approval in System Settings.
    var isOn: Bool { status == .enabled || status == .requiresApproval }
    var needsApproval: Bool { status == .requiresApproval }

    /// A copy run from the repository or a scratch folder must not become the login item: the
    /// system would remember that path. Only the installed app can.
    var isAvailable: Bool {
        Bundle.main.bundleURL.path.hasPrefix("/Applications/") && AppPaths.override == nil
    }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func set(_ on: Bool) {
        guard isAvailable else { return }
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            problem = nil
        } catch {
            // The system's wording is English and technical; keep it out of the UI, log it.
            Log.app.error("login item \(on ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            Diagnostics.error("launchAtLogin.change", error)
            problem = on
                ? "Fluence n'a pas pu s'ajouter aux éléments d'ouverture. Essayez depuis Réglages Système."
                : "Fluence n'a pas pu se retirer des éléments d'ouverture. Essayez depuis Réglages Système."
        }
        refresh()
    }

    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
