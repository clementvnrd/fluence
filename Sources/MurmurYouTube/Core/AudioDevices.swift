import CoreAudio
import Foundation
import OSLog

/// Representation of an audio input device detected by macOS CoreAudio.
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: String // UID string
    public let deviceID: AudioDeviceID
    public let name: String
    public let isDefault: Bool
    public let isBuiltIn: Bool
    public let transportType: UInt32

    public init(
        id: String,
        deviceID: AudioDeviceID,
        name: String,
        isDefault: Bool = false,
        isBuiltIn: Bool = false,
        transportType: UInt32 = 0
    ) {
        self.id = id
        self.deviceID = deviceID
        self.name = name
        self.isDefault = isDefault
        self.isBuiltIn = isBuiltIn
        self.transportType = transportType
    }

    /// System icon suitable for this device type.
    public var iconName: String {
        let lower = name.lowercased()
        if lower.contains("c920") || lower.contains("cam") || lower.contains("webcam") {
            return "video.fill"
        }
        if lower.contains("airpod") {
            return "airpodspro"
        }
        if lower.contains("iphone") {
            return "iphone"
        }
        if lower.contains("headset") || lower.contains("headphones") {
            return "headphones"
        }
        if isBuiltIn || lower.contains("macbook") || lower.contains("interne") || lower.contains("built-in") {
            return "laptopcomputer"
        }
        return "mic.fill"
    }

    /// Friendly subtitle describing the connection type.
    public var typeDescription: String {
        if isBuiltIn {
            return "Microphone intégré"
        }
        switch transportType {
        case kAudioDeviceTransportTypeUSB:
            return "Microphone USB"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "Audio Bluetooth"
        case kAudioDeviceTransportTypeVirtual:
            return "Périphérique virtuel"
        default:
            return "Entrée audio externe"
        }
    }
}

/// Helper querying CoreAudio hardware properties to list, inspect, and select audio input devices.
public enum AudioDevices {
    private static let logger = Logger(subsystem: "ai.pivotstudio.murmur-youtube", category: "audio-devices")

    /// Returns all audio devices capable of input (microphones).
    public static func availableInputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        )
        guard status == noErr, dataSize > 0 else {
            logger.warning("failed to get audio devices list size: \(status)")
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else {
            logger.warning("failed to get audio devices list: \(status)")
            return []
        }

        let defaultID = defaultInputDeviceID()
        var results: [AudioInputDevice] = []

        for id in deviceIDs {
            // Check for input streams
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(id, &streamAddress, 0, nil, &streamSize)
            guard status == noErr, streamSize > 0 else { continue }

            // Check channel configuration to confirm it has >0 input channels
            var configAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var configSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(id, &configAddress, 0, nil, &configSize)
            guard status == noErr, configSize > 0 else { continue }

            let rawBuffer = UnsafeMutableRawPointer.allocate(
                byteCount: Int(configSize),
                alignment: MemoryLayout<AudioBufferList>.alignment
            )
            var channelCount: UInt32 = 0
            status = AudioObjectGetPropertyData(id, &configAddress, 0, nil, &configSize, rawBuffer)
            if status == noErr {
                let bufferList = rawBuffer.assumingMemoryBound(to: AudioBufferList.self)
                let numBuffers = Int(bufferList.pointee.mNumberBuffers)
                withUnsafePointer(to: &bufferList.pointee.mBuffers) { ptr in
                    let buffers = UnsafeBufferPointer(start: ptr, count: numBuffers)
                    for buf in buffers {
                        channelCount += buf.mNumberChannels
                    }
                }
            }
            rawBuffer.deallocate()
            guard channelCount > 0 else { continue }

            // Get Device Name
            let name = stringProperty(
                selector: kAudioObjectPropertyName,
                scope: kAudioObjectPropertyScopeGlobal,
                deviceID: id
            ) ?? "Microphone (\(id))"

            // Get Device UID
            let uid = stringProperty(
                selector: kAudioDevicePropertyDeviceUID,
                scope: kAudioObjectPropertyScopeGlobal,
                deviceID: id
            ) ?? "\(id)"

            // Get Transport Type
            var transportType: UInt32 = 0
            var transportSize = UInt32(MemoryLayout<UInt32>.size)
            var transportAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyTransportType,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var isBuiltIn = false
            if AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transportType) == noErr {
                isBuiltIn = (transportType == kAudioDeviceTransportTypeBuiltIn)
            }

            let isDefault = (id == defaultID)

            results.append(AudioInputDevice(
                id: uid,
                deviceID: id,
                name: name,
                isDefault: isDefault,
                isBuiltIn: isBuiltIn,
                transportType: transportType
            ))
        }

        return results
    }

    /// Returns the system's current default input device ID.
    public static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown, deviceID != 0 else { return nil }
        return deviceID
    }

    /// Resolves a stored device UID (or "default") to an active AudioDeviceID.
    public static func deviceID(for uid: String) -> AudioDeviceID? {
        if uid.isEmpty || uid == "default" {
            return defaultInputDeviceID()
        }

        // Try fast translation via CoreAudio
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var cfUID: CFString = uid as CFString
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = withUnsafePointer(to: &cfUID) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPtr,
                &size,
                &deviceID
            )
        }

        if status == noErr, deviceID != kAudioObjectUnknown, deviceID != 0 {
            return deviceID
        }

        // Fallback search through enumerated devices
        return availableInputDevices().first(where: { $0.id == uid })?.deviceID
    }

    private static func stringProperty(
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope,
        deviceID: AudioDeviceID
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &address,
            0,
            nil,
            &size,
            &unmanaged
        )
        guard status == noErr, let unmanaged else { return nil }
        return unmanaged.takeRetainedValue() as String
    }
}
