import AVFoundation
import CoreAudio
import Foundation

/// The system side of a meeting: everyone else, as the meeting app plays them.
///
/// A Core Audio **process tap** (macOS 14.2+, `bundleIDs` since macOS 26) feeding a
/// private aggregate device, read by an IOProc. Permission is the "System Audio Recording
/// Only" TCC service (`NSAudioCaptureUsageDescription`), much lighter than Screen
/// Recording. Reference: insidegui/AudioCap.
///
/// - **Scope.** For a known app, the tap names the app's bundle IDs — every process of the
///   family seen in the process list at start (browsers play audio from helper processes,
///   Safari from `com.apple.WebKit.GPU`), plus the main bundle ID — with process restore
///   on, so a helper that restarts is picked up again. If that tap cannot be created the
///   same processes are tapped by object ID; failing that (or with no app: a manual
///   recording), a global tap of everything except Fluence.
/// - **Host.** The aggregate device is clocked by the built-in output, which survives
///   Bluetooth headphones switching profile or disconnecting mid-call.
/// - **Silence.** Permission denied is not an error: the tap delivers zeros. The
///   controller's watchdog compares `secondsSinceSignal` with whether the app is actually
///   playing, and rebuilds the tap or tells the user.
final class SystemAudioTap: @unchecked Sendable {
    enum Failure: LocalizedError {
        case tap(OSStatus)
        case format
        case aggregate(OSStatus)
        case ioProc(OSStatus)

        var errorDescription: String? {
            switch self {
            case .tap(let status): "Impossible de capter l'audio de la réunion (\(status))."
            case .format: "Le format audio de la réunion n'est pas pris en charge."
            case .aggregate(let status): "Impossible de créer le périphérique de capture (\(status))."
            case .ioProc(let status): "Impossible de démarrer le périphérique de capture (\(status))."
            }
        }
    }

    /// What was actually tapped, for the log and the UI.
    enum Scope: String {
        case bundleIDs, processes, global
    }

    private let app: MeetingApp?
    private let queue = DispatchQueue(label: "fluence.meeting.tap", qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private(set) var scope: Scope = .global

    private let lock = NSLock()
    private var startedAt: UInt64 = 0
    private var lastSignal: UInt64 = 0
    private var hasEverHadSignal = false

    init(app: MeetingApp?) {
        self.app = app
    }

    /// The bundle IDs of the processes that make up the app right now.
    static func processes(of app: MeetingApp) -> [CoreAudioObjects.Process] {
        CoreAudioObjects.processes().filter { app.matches($0.bundleID) }
    }

    /// Whether the meeting app (or, for a global tap, anything but Fluence) is playing
    /// audio right now.
    func isSourcePlaying() -> Bool {
        let own = ProcessInfo.processInfo.processIdentifier
        return CoreAudioObjects.processes().contains { process in
            guard process.isRunningOutput, process.pid != own else { return false }
            return app.map { $0.matches(process.bundleID) } ?? true
        }
    }

    /// Seconds since the last non-silent block (or since start when there was none), and
    /// whether any signal has been seen since start.
    func signalStatus() -> (secondsSinceSignal: TimeInterval, everHadSignal: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let reference = hasEverHadSignal ? lastSignal : startedAt
        guard reference > 0 else { return (0, false) }
        return (MeetingAudioFormat.seconds(from: reference, to: MeetingAudioFormat.now), hasEverHadSignal)
    }

    // MARK: - Lifecycle

    func start(onAudio: @escaping @Sendable (CapturedAudio) -> Void) throws {
        try createTap()
        let format: AVAudioFormat
        do {
            format = try tapFormat()
            try createAggregate()
            try startIO(format: format, onAudio: onAudio)
        } catch {
            stop()
            throw error
        }
        lock.lock()
        startedAt = MeetingAudioFormat.now
        lastSignal = 0
        hasEverHadSignal = false
        lock.unlock()
        // macOS has now asked for System Audio Recording, if it ever will (FLU-45).
        UserDefaults.standard.set(true, forKey: MeetingPreparation.systemAudioAskedKey)
        // The buffers are read at the tap's rate while the aggregate runs on its own clock;
        // log both so a mismatch (garbled remote audio) shows on the first real meeting.
        let deviceRate = CoreAudioObjects.value(aggregateID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0)) ?? 0
        Log.audio.info("system tap started (\(self.scope.rawValue, privacy: .public)) — tap \(format.sampleRate)Hz × \(format.channelCount), device \(deviceRate)Hz")
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: - Steps

    private func createTap() throws {
        let own = CoreAudioObjects.ownProcessObject
        var attempts: [(Scope, CATapDescription)] = []

        if let app {
            let processes = Self.processes(of: app)
            var bundleIDs = Set(processes.map(\.bundleID).filter { !$0.isEmpty })
            bundleIDs.insert(app.mainBundleID)

            let byBundle = CATapDescription()
            byBundle.bundleIDs = Array(bundleIDs).sorted()
            byBundle.isProcessRestoreEnabled = true
            byBundle.isMono = true
            byBundle.isMixdown = true
            byBundle.isExclusive = false
            attempts.append((.bundleIDs, byBundle))

            let objects = processes.map(\.objectID)
            if !objects.isEmpty {
                attempts.append((.processes, CATapDescription(monoMixdownOfProcesses: objects)))
            }
        }
        attempts.append((.global, CATapDescription(monoGlobalTapButExcludeProcesses: own.map { [$0] } ?? [])))

        var lastStatus: OSStatus = noErr
        for (scope, description) in attempts {
            description.name = "Fluence meeting"
            description.uuid = UUID()
            description.isPrivate = true
            description.muteBehavior = .unmuted
            var id = AudioObjectID(kAudioObjectUnknown)
            lastStatus = AudioHardwareCreateProcessTap(description, &id)
            if lastStatus == noErr, id != kAudioObjectUnknown {
                tapID = id
                self.scope = scope
                return
            }
            Log.audio.error("process tap (\(scope.rawValue, privacy: .public)) failed: \(lastStatus)")
            Diagnostics.error("meeting.systemTap", code: Int(lastStatus))
        }
        throw Failure.tap(lastStatus)
    }

    private func tapFormat() throws -> AVAudioFormat {
        guard var description = CoreAudioObjects.value(tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription()),
              description.mSampleRate > 0,
              let format = AVAudioFormat(streamDescription: &description)
        else { throw Failure.format }
        return format
    }

    private func createAggregate() throws {
        guard let tapUID = CoreAudioObjects.string(tapID, kAudioTapPropertyUID) else { throw Failure.format }
        let host = CoreAudioObjects.builtInOutputDevice ?? CoreAudioObjects.defaultOutputDevice
        let hostUID = host.flatMap(CoreAudioObjects.uid)

        var description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Fluence meeting capture",
            kAudioAggregateDeviceUIDKey: "io.github.clementvnrd.fluence.meeting." + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: tapUID],
            ],
        ]
        if let hostUID {
            description[kAudioAggregateDeviceMainSubDeviceKey] = hostUID
            description[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: hostUID]]
        }

        var id = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &id)
        guard status == noErr, id != kAudioObjectUnknown else { throw Failure.aggregate(status) }
        aggregateID = id
    }

    private func startIO(format: AVAudioFormat, onAudio: @escaping @Sendable (CapturedAudio) -> Void) throws {
        guard let converter = PCMConverter(from: format) else { throw Failure.format }
        let signal = SignalMeter(owner: self)

        var procID: AudioDeviceIOProcID?
        var status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, queue) { _, inputData, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil),
                  buffer.frameLength > 0
            else { return }
            let samples = converter.convert(buffer)
            guard !samples.isEmpty else { return }

            let time = inputTime.pointee
            let hostTime = time.mFlags.contains(.hostTimeValid)
                ? time.mHostTime
                : MeetingAudioFormat.hostTime(MeetingAudioFormat.now, minus: Double(buffer.frameLength) / format.sampleRate)
            signal.observe(samples, at: hostTime)
            onAudio(CapturedAudio(samples: samples, hostTime: hostTime, source: .system))
        }
        guard status == noErr, let procID else { throw Failure.ioProc(status) }
        self.procID = procID

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else { throw Failure.ioProc(status) }
    }

    fileprivate func noteSignal(at hostTime: UInt64) {
        lock.lock()
        lastSignal = hostTime
        hasEverHadSignal = true
        lock.unlock()
    }

    /// Records when the tap last carried anything above the noise floor of a muted stream.
    private final class SignalMeter: @unchecked Sendable {
        weak var owner: SystemAudioTap?
        init(owner: SystemAudioTap) { self.owner = owner }

        func observe(_ samples: [Float], at hostTime: UInt64) {
            var peak: Float = 0
            for sample in samples { peak = max(peak, abs(sample)) }
            if peak > 1e-5 { owner?.noteSignal(at: hostTime) }
        }
    }
}
