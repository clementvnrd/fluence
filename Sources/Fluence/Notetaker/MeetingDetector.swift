import AppKit
import CoreAudio
import Foundation

/// A call the detector has noticed. Offered to the user by the detection card; never
/// recorded without them.
struct DetectedMeeting: Sendable, Equatable {
    var app: MeetingApp
    /// The service shown in a browser's window title ("Google Meet"), or the app's name.
    var service: String
    /// Pid of the app the user sees (for Accessibility).
    var pid: pid_t?

    var displayName: String { app.isBrowser ? "\(service) dans \(app.name)" : service }
}

/// Watches for calls the way the orange mic dot does.
///
/// A listener on the default input device's `kAudioDevicePropertyDeviceIsRunningSomewhere`
/// wakes the detector when anyone opens the mic. While the mic is in use the process list
/// is polled (per-process listeners are unreliable): which processes are running input,
/// which meeting app or browser they belong to, and — for a browser — whether one of its
/// windows is actually a call. Each app is offered once per use of the mic: after "Not
/// now" it is not offered again until it has released the microphone.
///
/// The same poll answers "is the meeting app still on the mic?", which ends a recording
/// when the call ends.
@MainActor
final class MeetingDetector {
    /// Called for a newly detected call.
    var onDetected: ((DetectedMeeting) -> Void)?

    private var inputDevice: AudioObjectID?
    private var runningListener: AudioObjectPropertyListenerBlock?
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?
    private var pollTask: Task<Void, Never>?
    /// Families (by main bundle ID) already offered during their current use of the mic.
    private var offered: Set<String> = []
    /// Families seen on the mic in the last poll.
    private(set) var appsOnMicrophone: Set<String> = []
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "uk.co.delff.fluence"
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    private(set) var isRunning = false

    func start() {
        guard !isRunning else { return }
        isRunning = true
        listenForDefaultDeviceChanges()
        attachToInputDevice()
        Log.app.info("meeting detector started")
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        detachFromInputDevice()
        if let defaultDeviceListener {
            var address = CoreAudioObjects.address(kAudioHardwarePropertyDefaultInputDevice)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, defaultDeviceListener)
        }
        defaultDeviceListener = nil
        pollTask?.cancel()
        pollTask = nil
        offered.removeAll()
        Log.app.info("meeting detector stopped")
    }

    /// Whether any process of `app` was running input at the last poll.
    func isOnMicrophone(_ app: MeetingApp) -> Bool {
        appsOnMicrophone.contains(app.mainBundleID)
    }

    /// Marks an app as already offered (used when the user starts a recording by hand).
    func markOffered(_ app: MeetingApp) {
        offered.insert(app.mainBundleID)
    }

    /// Keeps the process list fresh while a recording needs "is the app still on the
    /// mic?", even if the device listener is quiet.
    func ensurePolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let keepGoing = self.poll()
                if !keepGoing && !self.keepPollingWhileRecording { break }
                try? await Task.sleep(for: .seconds(2))
            }
            self?.pollTask = nil
        }
    }

    /// Set by the controller while a recording is running.
    var keepPollingWhileRecording = false {
        didSet { if keepPollingWhileRecording { ensurePolling() } }
    }

    // MARK: - Listeners

    private func listenForDefaultDeviceChanges() {
        var address = CoreAudioObjects.address(kAudioHardwarePropertyDefaultInputDevice)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in
                self?.detachFromInputDevice()
                self?.attachToInputDevice()
            }
        }
        defaultDeviceListener = block
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
    }

    private func attachToInputDevice() {
        guard isRunning, let device = CoreAudioObjects.defaultInputDevice else { return }
        inputDevice = device
        var address = CoreAudioObjects.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.ensurePolling() }
        }
        runningListener = block
        AudioObjectAddPropertyListenerBlock(device, &address, .main, block)
        if CoreAudioObjects.isRunningSomewhere(device) { ensurePolling() }
    }

    private func detachFromInputDevice() {
        if let device = inputDevice, let runningListener {
            var address = CoreAudioObjects.address(kAudioDevicePropertyDeviceIsRunningSomewhere)
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, runningListener)
        }
        inputDevice = nil
        runningListener = nil
    }

    // MARK: - Polling

    /// One look at the process list. Returns whether the mic is still in use by anyone
    /// other than Fluence (polling continues while it is).
    @discardableResult
    private func poll() -> Bool {
        let inputs = CoreAudioObjects.processes().filter { process in
            process.isRunningInput && process.pid != ownPID && process.bundleID != ownBundleID
        }

        var onMic: [String: MeetingApp] = [:]
        for process in inputs {
            guard let app = MeetingApps.identify(process.bundleID) else { continue }
            onMic[app.mainBundleID] = app
        }
        appsOnMicrophone = Set(onMic.keys)
        // An app that released the mic may be offered again next time.
        offered.formIntersection(appsOnMicrophone)

        guard NotetakerSettings.shared.detectMeetings else { return !inputs.isEmpty }

        for app in onMic.values where !offered.contains(app.mainBundleID) {
            let pid = MeetingWindowReader.mainPID(for: app)
            let service: String
            if app.isBrowser {
                // A browser with the mic open is only a call when a window says so;
                // otherwise look again on the next poll (the user may switch tabs).
                guard let pid, let found = MeetingWindowReader.meetingService(pid: pid) else { continue }
                service = found
            } else {
                service = app.name
            }
            offered.insert(app.mainBundleID)
            Log.app.info("meeting detected: \(app.mainBundleID, privacy: .public)")
            onDetected?(DetectedMeeting(app: app, service: service, pid: pid))
        }
        return !inputs.isEmpty
    }
}
