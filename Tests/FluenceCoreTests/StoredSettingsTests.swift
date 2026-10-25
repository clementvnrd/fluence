import Foundation
import Testing

@testable import FluenceCore

/// R13: a corrupted setting used to crash every launch.
struct StoredSettingsTests {
    @Test func recordingLimitKeepsSaneValues() {
        for minutes in [1, 2, 5, 10, 30, 120] {
            #expect(StoredSettings.recordingLimit(minutes) == minutes)
        }
    }

    /// `limit * 60` trapped on a huge value; only `> 0` was checked.
    @Test func recordingLimitFallsBackOnAbsurdValues() {
        for minutes in [0, -1, 121, Int.max, Int.max / 60 + 1, Int.min] {
            #expect(StoredSettings.recordingLimit(minutes) == StoredSettings.defaultRecordingLimit)
        }
        // Whatever comes back is safe to turn into seconds.
        let seconds = StoredSettings.recordingLimit(Int.max).multipliedReportingOverflow(by: 60)
        #expect(!seconds.overflow)
    }

    @Test func meetingDurationFallsBackOnAbsurdValues() {
        #expect(StoredSettings.meetingDuration(nil) == 180)
        #expect(StoredSettings.meetingDuration(240) == 240)
        for minutes in [0, -5, 24 * 60 + 1, Int.max] {
            #expect(StoredSettings.meetingDuration(minutes) == 180)
        }
    }

    @Test func aCorruptedRetentionKeepsMeetings() {
        #expect(StoredSettings.meetingRetention(30) == 30)
        #expect(StoredSettings.meetingRetention(0) == nil)
        #expect(StoredSettings.meetingRetention(-30) == nil)
        #expect(StoredSettings.meetingRetention(Int.max) == nil)
    }

    @Test func comboParsesWhatSettingsWrites() {
        let combo = ShortcutCombo(rawValue: "combo:49:524288:false:⌥ Espace:Option + Espace")
        #expect(combo?.keyCode == 49)
        #expect(combo?.modifierFlags == 524_288)
        #expect(combo?.isModifierOnly == false)
        #expect(combo?.shortName == "⌥ Espace")
        #expect(combo?.displayName == "Option + Espace")
    }

    /// `UInt32(keyCode)` in the hotkey monitor trapped on these.
    @Test func comboRefusesKeyCodesNoKeyboardSends() {
        for code in ["-1", "65536", "4294967296", "9223372036854775807", "-9223372036854775808", "x"] {
            #expect(ShortcutCombo(rawValue: "combo:\(code):0:false:a:b") == nil)
        }
    }

    @Test func comboRefusesMalformedValues() {
        #expect(ShortcutCombo(rawValue: "combo:49:0:false:short") == nil)
        #expect(ShortcutCombo(rawValue: "combo:49:-1:false:a:b") == nil)
        #expect(ShortcutCombo(rawValue: "combo:49:0:maybe:a:b") == nil)
        #expect(ShortcutCombo(rawValue: "chord:49:0:false:a:b") == nil)
    }
}
