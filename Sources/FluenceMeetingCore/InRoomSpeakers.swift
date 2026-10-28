import Foundation

/// The people around the user's microphone (FLU-33, hidden setting, off by default).
///
/// Normally the mic channel is the user by construction and never diarized, so a colleague
/// sitting beside them is « Vous » too. With the setting on, the mic channel goes through the
/// same diarizer and consolidation as the call; then the voice that said the most of the
/// mic's own words is the user (`Speaker.meID`) and every other one is someone in the
/// room, labelled `R1…Rn` in order of first appearance
/// (`SpeakerAssignment.attribute(labelPrefix:)`) and shown as « Sur place 1 ». Those voices are never named from the call window or the calendar: the
/// window lists the people *in the call*, and nothing says who sits in the room.
public enum InRoomSpeakers {
    /// Prefix of the labels of in-room voices.
    public static let labelPrefix = "R"

    /// The mic diarizer's turns with the user's voice (`userVoice`) renamed `Speaker.meID`;
    /// the others keep their diarizer label, for `SpeakerAssignment` to relabel.
    public static func relabel(_ turns: [SpeakerTurn], words: [Word] = []) -> [SpeakerTurn] {
        guard let user = userVoice(turns, words: words) else { return turns }
        return turns.map { turn in
            var copy = turn
            if turn.speaker == user {
                copy.speaker = Speaker.meID
            } else if turn.speaker == Speaker.meID {
                // A diarizer label that happens to be « me » must not join the user.
                copy.speaker = labelPrefix + "?" + turn.speaker
            }
            return copy
        }
    }

    /// The user's voice on the mic: the one that said the most of `words` by duration —
    /// the mic's words once echoes of the call are dropped, so a call played through the
    /// speakers cannot take the user's place however long it talks. Without a word any
    /// turn covers, the voice with the most speech. Ties: the voice heard first.
    public static func userVoice(_ turns: [SpeakerTurn], words: [Word]) -> String? {
        var said: [String: TimeInterval] = [:]
        for word in words {
            guard let voice = SpeakerAssignment.speaker(start: word.start, end: word.end, turns: turns) else { continue }
            said[voice, default: 0] += max(word.end - word.start, 0.01)
        }
        guard !said.isEmpty else { return largestVoice(turns) }
        let order = firstHeard(turns)
        return said.keys.max { a, b in
            let sa = said[a] ?? 0, sb = said[b] ?? 0
            if sa != sb { return sa < sb }
            return (order.firstIndex(of: a) ?? .max) > (order.firstIndex(of: b) ?? .max)
        }
    }

    private static func firstHeard(_ turns: [SpeakerTurn]) -> [String] {
        var order: [String] = []
        for turn in turns where !order.contains(turn.speaker) { order.append(turn.speaker) }
        return order
    }

    /// The voice with the most speech; on a tie, the one heard first.
    public static func largestVoice(_ turns: [SpeakerTurn]) -> String? {
        var speech: [String: TimeInterval] = [:]
        var order: [String] = []
        for turn in turns {
            if speech[turn.speaker] == nil { order.append(turn.speaker) }
            speech[turn.speaker, default: 0] += max(0, turn.end - turn.start)
        }
        return order.max { a, b in
            let sa = speech[a] ?? 0, sb = speech[b] ?? 0
            if sa != sb { return sa < sb }
            return order.firstIndex(of: a)! > order.firstIndex(of: b)!
        }
    }
}

extension Speaker {
    /// Someone in the room with the user, heard on the mic (FLU-33): `R1`, `R2`…
    public var isInRoom: Bool {
        id.hasPrefix(InRoomSpeakers.labelPrefix) && id.count > 1 && id.dropFirst().allSatisfy(\.isNumber)
    }
}
