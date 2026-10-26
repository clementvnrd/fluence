import AppKit
import FluenceCore
import UserNotifications

/// « Fluence x.y.z est prête » (FLU-80): the macOS notification for an update downloaded
/// while Fluence stays in the menu bar. *Installer* installs and relaunches without bringing
/// Fluence forward; a click on the banner opens Fluence on the usual question.
///
/// Only a build with an updater touches the notification center (`AppUpdater.start`), and
/// permission is asked the first time a notification is due, never at launch. Refused: the
/// item at the top of the menu bar menu and the dot on its icon are all the user gets.
///
/// A non-sandboxed app needs no entitlement for this.
@MainActor
final class UpdateNotifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotifier()

    /// *Installer* on the notification.
    var onInstall: (() -> Void)?
    /// A click on the banner itself.
    var onOpen: (() -> Void)?

    private var isConfigured = false

    /// At launch, so the answer to a notification reaches us even when it launched the app.
    /// Registers the *Installer* button; asks for nothing.
    func configure() {
        guard !isConfigured else { return }
        isConfigured = true
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let install = UNNotificationAction(
            identifier: UpdateNotificationPolicy.installAction,
            title: UpdateNotificationPolicy.installTitle,
            options: []
        )
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: UpdateNotificationPolicy.category,
                actions: [install],
                intentIdentifiers: [],
                options: []
            ),
        ])
    }

    /// Asks for permission (the system shows its question once), then posts.
    func post(version: String) {
        guard isConfigured else { return }
        Task {
            let center = UNUserNotificationCenter.current()
            do {
                guard try await center.requestAuthorization(options: [.alert]) else {
                    Log.app.info("updates: notifications not allowed, \(version, privacy: .public) waits in the menu")
                    return
                }
                let content = UNMutableNotificationContent()
                content.title = UpdateNotificationPolicy.title(version: version)
                content.body = UpdateNotificationPolicy.body
                content.categoryIdentifier = UpdateNotificationPolicy.category
                let request = UNNotificationRequest(
                    identifier: UpdateNotificationPolicy.identifier, content: content, trigger: nil
                )
                try await center.add(request)
                Log.app.info("updates: notification posted for \(version, privacy: .public)")
            } catch {
                let error = error as NSError
                Log.app.error("updates: notification failed — \(error.domain, privacy: .public) \(error.code, privacy: .public)")
                Diagnostics.error("updates.notification", error)
            }
        }
    }

    /// Takes the banner out of Notification Center once it has done its job.
    func withdraw() {
        guard isConfigured else { return }
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [UpdateNotificationPolicy.identifier])
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let isUpdate = response.notification.request.content.categoryIdentifier == UpdateNotificationPolicy.category
        let action = response.actionIdentifier
        completionHandler()
        guard isUpdate else { return }
        Task { @MainActor in
            switch action {
            case UpdateNotificationPolicy.installAction:
                Log.app.info("updates: Installer chosen on the notification")
                self.onInstall?()
            case UNNotificationDefaultActionIdentifier:
                Log.app.info("updates: notification opened")
                self.onOpen?()
            default:
                break
            }
        }
    }

    /// Fluence in front: no banner. The question « Fluence x.y.z est disponible » is asked
    /// there instead.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([])
    }
}
