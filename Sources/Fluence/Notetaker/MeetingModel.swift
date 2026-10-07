import Foundation
@_exported import FluenceMeetingCore

// The meeting model itself lives in FluenceMeetingCore (Sources/FluenceMeetingCore/
// MeetingModel.swift) so it can be unit-tested without AppKit. Re-exported here so every
// file in the app sees `Meeting`, `Speaker`, `TranscriptSegment`… without an import.

// FluidAudio also declares public `Speaker` and `AudioSource` types. A module-level alias
// in the app shadows both imports, so files that import FluidAudio still mean ours.
typealias Speaker = FluenceMeetingCore.Speaker
typealias AudioSource = FluenceMeetingCore.AudioSource

extension Notification.Name {
    /// Posted on the main actor once a meeting's final pass (diarization, naming) is saved.
    /// `object` is the meeting's `UUID`. The notes generator listens for it.
    static let meetingFinalized = Notification.Name("FluenceMeetingFinalized")
}
