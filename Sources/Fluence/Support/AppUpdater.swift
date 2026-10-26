import AppKit
import FluenceCore
import Observation
import Sparkle

/// In-app updates (FLU-26), with Sparkle 2.
///
/// Sparkle reads the feed named in Info.plist (`SUFeedURL`, stamped by the Makefile) at
/// launch and then once a day, downloads a new version in the background
/// (`SUAutomaticallyUpdate`), and refuses it unless its EdDSA signature matches
/// `SUPublicEDKey` and its code signature matches this app's. It then hands the moment of
/// installing to us (`willInstallUpdateOnQuit`): we ask once — « Fluence x.y.z est disponible »,
/// *Installer* / *Plus tard* — only while the user is in Fluence and nothing is recording.
/// *Plus tard* leaves it to Sparkle, which installs it when Fluence quits.
///
/// FLU-80: Fluence mostly lives in the menu bar, where that question never showed. While a
/// version waits, « Installer Fluence x.y.z » heads the menu bar menu and a blue dot sits on
/// its icon; and when it arrives with Fluence in the background, one notification per version
/// says « Fluence x.y.z est prête » (`UpdateNotifier`), its *Installer* installing straight away.
/// The rules are `UpdateMenuItem` and `UpdateNotificationPolicy`.
///
/// Never during a dictation or a meeting: a dialog would take the focus the dictation types
/// into, and a relaunch would end the recording (`UpdatePolicy`). An *Installer* chosen during
/// one installs when it ends.
///
/// The feed request is the app's only outgoing connection besides model downloads; it carries
/// no system profile and no identifier (`SUEnableSystemProfiling` is off).
@MainActor
@Observable
final class AppUpdater: NSObject, SPUUpdaterDelegate {
    static let shared = AppUpdater()

    /// A downloaded and verified version waiting to be installed, for the menus.
    private(set) var readyVersion: String?

    /// Set by the app delegate from the dictation and meeting states.
    var recording: UpdateRecording = .none {
        didSet { if oldValue.isBusy, !recording.isBusy { busyEnded() } }
    }

    var isBusy: Bool { recording.isBusy }

    /// The item at the top of the menu bar menu (FLU-80).
    var menuItem: UpdateMenuItem {
        UpdateMenuItem.resolve(updaterRunning: isRunning, readyVersion: readyVersion, recording: recording)
    }

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var installNow: (() -> Void)?
    @ObservationIgnored private var relaunchWhenIdle: (() -> Void)?
    @ObservationIgnored private var notes: String?
    @ObservationIgnored private var hasOffered = false
    @ObservationIgnored private var isOffering = false
    @ObservationIgnored private var lastAnswer: Date?
    @ObservationIgnored private var activation: NSObjectProtocol?

    /// A build without a feed or a public key (a local `make app` with `FEED_URL=`) never
    /// starts Sparkle, rather than failing on every check.
    static var isConfigured: Bool {
        let info = Bundle.main.infoDictionary ?? [:]
        let feed = (info["SUFeedURL"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let key = (info["SUPublicEDKey"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return !feed.isEmpty && !key.isEmpty
    }

    var isRunning: Bool { controller != nil }

    func start() {
        guard controller == nil else { return }
        guard Self.isConfigured else {
            Log.app.info("updates: no feed in this build")
            return
        }
        // Before Sparkle starts: the answer to a notification may be what launched us.
        let notifier = UpdateNotifier.shared
        notifier.onInstall = { [weak self] in self?.install(from: .notification) }
        notifier.onOpen = { [weak self] in self?.openFromNotification() }
        notifier.configure()
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: self, userDriverDelegate: nil)
        activation = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.offerIfPossible() }
        }
    }

    /// « Rechercher des mises à jour… »: Sparkle's own window (in French), or straight to the
    /// question when a version is already downloaded.
    func checkNow() {
        NSApp.activate(ignoringOtherApps: true)
        if installNow != nil {
            offerIfPossible(userAsked: true)
        } else {
            controller?.checkForUpdates(nil)
        }
    }

    /// « Installer Fluence x.y.z » at the top of the menu bar menu, or *Installer* on the
    /// notification: no question, it installs and relaunches — once the recording has ended
    /// if one is under way.
    enum InstallSource: String { case menu = "menu", notification = "notification" }

    func install(from source: InstallSource) {
        guard let installNow, let version = readyVersion else {
            Log.app.info("updates: install asked from the \(source.rawValue, privacy: .public) with nothing waiting")
            return
        }
        UpdateNotifier.shared.withdraw()
        guard UpdatePolicy.mayRelaunch(isBusy: isBusy) else {
            relaunchWhenIdle = installNow
            Log.app.info("updates: \(version, privacy: .public) asked from the \(source.rawValue, privacy: .public), installs when the recording ends")
            return
        }
        Log.app.info("updates: installing \(version, privacy: .public) now, from the \(source.rawValue, privacy: .public)")
        installNow()
    }

    /// Réglages › À propos › Mises à jour automatiques.
    var checksAutomatically: Bool {
        get { controller?.updater.automaticallyChecksForUpdates ?? false }
        set { controller?.updater.automaticallyChecksForUpdates = newValue }
    }

    var lastCheck: Date? { controller?.updater.lastUpdateCheckDate }

    // MARK: SPUUpdaterDelegate (called on the main thread: the protocol is main-actor)

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        readyVersion = item.displayVersionString
        notes = ReleaseNotesText.summary(fromHTML: item.itemDescription)
        installNow = immediateInstallHandler
        hasOffered = false
        lastAnswer = nil
        Log.app.info("updates: \(item.displayVersionString, privacy: .public) downloaded and verified")
        // Sparkle accepts the handler only once we have returned YES: ask on the next turn,
        // never from inside this callback.
        Task { @MainActor in
            self.offerIfPossible()
            self.notifyIfDue()
        }
        // We decide when to install; Sparkle still installs it on quit if the user waits.
        return true
    }

    func updater(
        _ updater: SPUUpdater,
        shouldPostponeRelaunchForUpdate item: SUAppcastItem,
        untilInvokingBlock installHandler: @escaping () -> Void
    ) -> Bool {
        guard !UpdatePolicy.mayRelaunch(isBusy: isBusy) else { return false }
        relaunchWhenIdle = installHandler
        Log.app.info("updates: relaunch postponed until the recording ends")
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: any Error) {
        // Domain and code only: a description can carry the feed's URL or a path.
        let error = error as NSError
        Log.app.info("updates: check ended — \(error.domain, privacy: .public) \(error.code, privacy: .public)")
    }

    // MARK: Telling the user

    /// FLU-80: one notification per version while Fluence is in the background. Remembered
    /// in the settings (a version number), so a relaunch does not post it again.
    private func notifyIfDue() {
        guard isRunning else { return }
        let defaults = AppPaths.defaults
        let notified = defaults.string(forKey: UpdateNotificationPolicy.notifiedVersionKey)
        guard UpdateNotificationPolicy.shouldPost(
            readyVersion: readyVersion,
            notifiedVersion: notified,
            alreadyAsked: hasOffered,
            appIsActive: NSApp.isActive,
            isBusy: isBusy
        ), let version = readyVersion else { return }
        // Written before posting: a refusal or a failure is not retried for this version.
        defaults.set(version, forKey: UpdateNotificationPolicy.notifiedVersionKey)
        UpdateNotifier.shared.post(version: version)
    }

    /// A click on the banner: Fluence opens and asks « Fluence x.y.z est disponible ». The
    /// activation may already have asked; never twice in a row.
    private func openFromNotification() {
        AppPresence.shared.reopenMainWindow()
        guard installNow != nil else { return }
        let again = UpdateNotificationPolicy.bannerClickAsksAgain(lastAnswer: lastAnswer, now: Date())
        Task { @MainActor in self.offerIfPossible(userAsked: again) }
    }

    private func offerIfPossible(userAsked: Bool = false) {
        guard let installNow, let version = readyVersion, !isOffering else { return }
        guard userAsked || !hasOffered else { return }
        guard UpdatePolicy.mayOffer(isBusy: isBusy, appIsActive: userAsked || NSApp.isActive) else { return }
        isOffering = true
        hasOffered = true
        defer {
            isOffering = false
            lastAnswer = Date()
        }
        UpdateNotifier.shared.withdraw()

        let alert = NSAlert()
        alert.messageText = "Fluence \(version) est disponible"
        alert.informativeText = [notes, "Plus tard : installée quand vous quitterez Fluence."]
            .compactMap { $0 }
            .joined(separator: "\n\n")
        alert.addButton(withTitle: "Installer")
        alert.addButton(withTitle: "Plus tard")
        Log.app.info("updates: asking about \(version, privacy: .public)")
        guard alert.runModal() == .alertFirstButtonReturn else {
            Log.app.info("updates: \(version, privacy: .public) left for the next quit")
            return
        }
        // A dictation or a meeting may have started while the question was up.
        guard UpdatePolicy.mayRelaunch(isBusy: isBusy) else {
            relaunchWhenIdle = installNow
            Log.app.info("updates: install postponed until the recording ends")
            return
        }
        Log.app.info("updates: installing \(version, privacy: .public) now")
        installNow()
    }

    private func busyEnded() {
        if let relaunch = relaunchWhenIdle {
            relaunchWhenIdle = nil
            Log.app.info("updates: recording ended, installing now")
            relaunch()
        } else {
            offerIfPossible()
            // Still in the background: the notification held back during the recording.
            notifyIfDue()
        }
    }
}
