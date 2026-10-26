import Foundation
import Testing

@testable import FluenceMeetingCore

/// FLU-33: the people in the room, when the mic channel is diarized (hidden setting).
struct InRoomSpeakersTests {
    @Test("the voice heard the most on the mic is the user; the others keep their label")
    func largestIsTheUser() {
        let turns = [
            SpeakerTurn(speaker: "spk_0", start: 0, end: 5),
            SpeakerTurn(speaker: "spk_1", start: 5, end: 30),
            SpeakerTurn(speaker: "spk_2", start: 30, end: 33),
            SpeakerTurn(speaker: "spk_0", start: 33, end: 40),
        ]
        #expect(InRoomSpeakers.relabel(turns).map(\.speaker) == ["spk_0", Speaker.meID, "spk_2", "spk_0"])
        #expect(InRoomSpeakers.largestVoice(turns) == "spk_1")
    }

    @Test("the call heard through the speakers is not the user, even when it speaks the most")
    func echoIsNotTheUser() {
        // The remote side, played aloud, fills 30 s of the mic; the user speaks 10 s. Only
        // the user's words survive echo removal.
        let turns = [SpeakerTurn(speaker: "call", start: 0, end: 30), SpeakerTurn(speaker: "user", start: 30, end: 40)]
        let kept = [Word(text: "d'accord", start: 31, end: 32), Word(text: "merci", start: 35, end: 36)]
        #expect(InRoomSpeakers.userVoice(turns, words: kept) == "user")
        #expect(InRoomSpeakers.relabel(turns, words: kept).map(\.speaker) == ["call", Speaker.meID])
        // Without words to go by, the most speech decides.
        #expect(InRoomSpeakers.userVoice(turns, words: []) == "call")
        // Words no turn covers do not decide either.
        #expect(InRoomSpeakers.userVoice(turns, words: [Word(text: "x", start: 100, end: 101)]) == "call")
    }

    @Test("on a tie, the voice heard first is the user")
    func tie() {
        let turns = [SpeakerTurn(speaker: "b", start: 0, end: 10), SpeakerTurn(speaker: "a", start: 10, end: 20)]
        #expect(InRoomSpeakers.largestVoice(turns) == "b")
    }

    @Test("no turns, nothing to relabel")
    func empty() {
        #expect(InRoomSpeakers.relabel([]).isEmpty)
        #expect(InRoomSpeakers.largestVoice([]) == nil)
    }

    @Test("a diarizer label that is already « me » does not join the user")
    func labelCollision() {
        let turns = [SpeakerTurn(speaker: "big", start: 0, end: 30), SpeakerTurn(speaker: Speaker.meID, start: 30, end: 35)]
        let relabelled = InRoomSpeakers.relabel(turns)
        #expect(relabelled[0].speaker == Speaker.meID)
        #expect(relabelled[1].speaker != Speaker.meID)
    }

    @Test("the whole chain: one mic, the user and a colleague")
    func attribution() {
        let words = [
            Word(text: "bonjour", start: 0.5, end: 1), Word(text: "à", start: 1, end: 1.2), Word(text: "tous", start: 1.2, end: 1.6),
            Word(text: "merci", start: 20.5, end: 21),
        ]
        let mic = [TranscriptSegment(source: .microphone, speakerID: Speaker.meID, start: 0, end: 21, text: "bonjour à tous merci", words: words)]
        let turns = InRoomSpeakers.relabel([
            SpeakerTurn(speaker: "spk_0", start: 0, end: 15),
            SpeakerTurn(speaker: "spk_1", start: 20, end: 22),
        ])
        let result = SpeakerAssignment.attribute(mic, turns: turns, fallbackID: Speaker.meID, labelPrefix: InRoomSpeakers.labelPrefix)
        #expect(result.segments.map(\.speakerID) == [Speaker.meID, "R1"])
        #expect(result.labels == ["spk_1": "R1"])
    }

    @Test("an in-room voice reads « Sur place n », a remote one still « Intervenant n »")
    func labels() {
        #expect(Speaker(id: "R1").isInRoom)
        #expect(Speaker(id: "R12").isInRoom)
        #expect(!Speaker(id: "R").isInRoom)
        #expect(!Speaker(id: "Rx").isInRoom)
        #expect(!Speaker(id: "S1").isInRoom)
        #expect(!Speaker.me().isInRoom)
        #expect(!Speaker.others.isInRoom)
        #expect(Speaker(id: "R2").displayName == "In the room 2")
        #expect(Speaker(id: "R2").frenchDisplayName == "Sur place 2")
        #expect(Speaker(id: "R2").isUnnamed)
        #expect(Speaker(id: "R2", name: "Ada", nameSource: .user).frenchDisplayName == "Ada")
        #expect(Speaker(id: "S2").frenchDisplayName == "Intervenant 2")
        #expect(SpeakerLabel.french(displayName: "In the room 3") == "Sur place 3")
        #expect(SpeakerLabel.french(displayName: "In the room") == "In the room")
        #expect(SpeakerLabel.french(displayName: "In the room x") == "In the room x")
    }
}
