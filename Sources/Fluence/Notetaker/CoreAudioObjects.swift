import AppKit
import CoreAudio
import Foundation

/// Thin, typed reads over the Core Audio object model, for the meeting detector and the
/// system-audio tap. Every call is a synchronous HAL query: cheap, but not for the
/// real-time thread.
enum CoreAudioObjects {
    /// A process the audio server knows about (macOS 14.2+ process objects).
    struct Process: Sendable, Hashable {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let isRunningInput: Bool
        let isRunningOutput: Bool
    }

    // MARK: - Generic reads

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) -> T? {
        var address = address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? value : nil
    }

    static func array<T>(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        of _: T.Type,
        zero: T
    ) -> [T] {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var values = [T](repeating: zero, count: Int(size) / MemoryLayout<T>.stride)
        let status = values.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return Array(values.prefix(Int(size) / MemoryLayout<T>.stride))
    }

    static func string(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> String? {
        var address = address(selector, scope: scope)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let result else { return nil }
        return result.takeRetainedValue() as String
    }

    // MARK: - Devices

    static var defaultInputDevice: AudioObjectID? {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, initial: AudioObjectID(0))
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    static var defaultOutputDevice: AudioObjectID? {
        value(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(0))
            .flatMap { $0 == kAudioObjectUnknown ? nil : $0 }
    }

    /// The same signal as the orange microphone dot: some process is using the device.
    static func isRunningSomewhere(_ device: AudioObjectID) -> Bool {
        (value(device, kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0)) ?? 0) != 0
    }

    static func uid(_ device: AudioObjectID) -> String? {
        string(device, kAudioDevicePropertyDeviceUID)
    }

    static func transportType(_ device: AudioObjectID) -> UInt32 {
        value(device, kAudioDevicePropertyTransportType, initial: UInt32(0)) ?? 0
    }

    static func outputDataSource(_ device: AudioObjectID) -> UInt32? {
        value(device, kAudioDevicePropertyDataSource, scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0))
    }

    static var allDevices: [AudioObjectID] {
        array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices, of: AudioObjectID.self, zero: 0)
    }

    static func hasOutputStreams(_ device: AudioObjectID) -> Bool {
        !array(device, kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput, of: AudioObjectID.self, zero: 0).isEmpty
    }

    /// The Mac's own speakers/headphone jack. Hosting the tap's aggregate device here keeps
    /// it alive when Bluetooth headphones switch profile or disconnect.
    static var builtInOutputDevice: AudioObjectID? {
        allDevices.first { device in
            transportType(device) == kAudioDeviceTransportTypeBuiltIn && hasOutputStreams(device)
        }
    }

    /// Whether the user hears the call privately (headphones), so the mic cannot pick up
    /// the remote side.
    static var outputIsHeadphones: Bool {
        guard let device = defaultOutputDevice else { return false }
        return OutputRoute.isHeadphones(transportType: transportType(device), dataSource: outputDataSource(device))
    }

    // MARK: - Processes

    static var ownProcessObject: AudioObjectID? {
        processObject(for: ProcessInfo.processInfo.processIdentifier)
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var qualifier = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &qualifier, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    /// Every process object, with its bundle ID (falling back to the running app's) and
    /// whether it is currently doing input/output. Polled, not observed: per-process
    /// listeners are unreliable.
    static func processes() -> [Process] {
        let objects = array(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList,
                            of: AudioObjectID.self, zero: 0)
        return objects.compactMap { object in
            guard let pid = value(object, kAudioProcessPropertyPID, initial: pid_t(0)), pid > 0 else { return nil }
            var bundleID = string(object, kAudioProcessPropertyBundleID) ?? ""
            if bundleID.isEmpty {
                bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? ""
            }
            return Process(
                objectID: object,
                pid: pid,
                bundleID: bundleID,
                isRunningInput: (value(object, kAudioProcessPropertyIsRunningInput, initial: UInt32(0)) ?? 0) != 0,
                isRunningOutput: (value(object, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0)) ?? 0) != 0
            )
        }
    }
}
