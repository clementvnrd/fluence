import Foundation
import Testing

@testable import FluenceMeetingCore

/// macOS-side unit tests for the pieces not covered by the shared vectors.
struct UtteranceSegmenterTests {
    private func run(_ probabilities: [Float], config: UtteranceSegmenter.Config = .init()) -> [Utterance] {
        var segmenter = UtteranceSegmenter(config: config)
        return probabilities.flatMap { segmenter.push($0) } + segmenter.finish()
    }

    private let hop = 4_096
    private let pad = 1_600

    @Test("speech closes after enough silence, padded both sides")
    func closesOnSilence() {
        let utterances = run([0, 0, 0.9, 0.9, 0.9, 0.1, 0.1, 0])
        #expect(utterances == [Utterance(startSample: 2 * hop - pad, endSample: 5 * hop + pad)])
    }

    @Test("a dip between the two thresholds does not end an utterance")
    func hysteresis() {
        let utterances = run([0.9, 0.4, 0.4, 0.4, 0.9, 0.1, 0.1])
        #expect(utterances == [Utterance(startSample: 0, endSample: 5 * hop + pad)])
    }

    @Test("long speech is cut at its least probable hop and continues")
    func maxDuration() {
        // 14.5 s cap = 57 hops. The first cut lands on the dip at hop 40; the second, with
        // no dip, on the latest hop of the second half.
        var probabilities = [Float](repeating: 0.9, count: 100)
        probabilities[40] = 0.5
        let utterances = run(probabilities)
        #expect(utterances == [
            Utterance(startSample: 0, endSample: 40 * hop),
            Utterance(startSample: 40 * hop, endSample: 96 * hop),
            Utterance(startSample: 96 * hop, endSample: 100 * hop),
        ])
        // Every utterance fits one Parakeet pass (240 000 samples).
        #expect(utterances.allSatisfy { $0.sampleCount <= 240_000 })
    }

    @Test("bursts shorter than the minimum are dropped")
    func minSpeech() {
        var config = UtteranceSegmenter.Config()
        config.minSpeech = 0.5
        #expect(run([0, 0.9, 0, 0, 0], config: config).isEmpty)
    }

    @Test("an utterance open at the end of the stream is flushed")
    func flush() {
        let utterances = run([0, 0.9, 0.9])
        #expect(utterances == [Utterance(startSample: hop - pad, endSample: 3 * hop)])
    }
}

struct TimelineAlignerTests {
    @Test("jitter is absorbed, gaps are padded, overlaps trimmed")
    func placement() {
        var aligner = TimelineAligner(sampleRate: 16_000, tolerance: 0.12)
        #expect(aligner.place(time: 0, count: 1_600) == .init(padding: 0, dropLeading: 0))
        #expect(aligner.place(time: 0.15, count: 1_600) == .init(padding: 0, dropLeading: 0))
        #expect(aligner.written == 3_200)
        #expect(aligner.place(time: 1.0, count: 1_600) == .init(padding: 12_800, dropLeading: 0))
        #expect(aligner.written == 17_600)
        #expect(aligner.place(time: 0.5, count: 1_600) == .init(padding: 0, dropLeading: 1_600))
        #expect(aligner.written == 17_600)
        #expect(aligner.padUntil(time: 2.0) == 32_000 - 17_600)
        #expect(aligner.padUntil(time: 2.05) == 0)
    }
}

struct StopPolicyTests {
    let policy = StopPolicy(maxDuration: 3 * 3600)

    @Test("call ended after 30 s without the app on the mic")
    func callEnded() {
        #expect(policy.reason(elapsed: 100, lastSpeech: 99, appLastUsingMic: 75) == nil)
        #expect(policy.reason(elapsed: 105, lastSpeech: 104, appLastUsingMic: 75) == .callEnded)
        #expect(policy.reason(elapsed: 105, lastSpeech: 104, appLastUsingMic: nil) == nil)
    }

    @Test("ten minutes of silence, and the hard cap")
    func silenceAndCap() {
        #expect(policy.reason(elapsed: 700, lastSpeech: 99, appLastUsingMic: 700) == .silence)
        #expect(policy.reason(elapsed: 599, lastSpeech: nil, appLastUsingMic: nil) == nil)
        #expect(policy.reason(elapsed: 600, lastSpeech: nil, appLastUsingMic: nil) == .silence)
        #expect(policy.reason(elapsed: 3 * 3600, lastSpeech: 3 * 3600, appLastUsingMic: nil) == .maxDuration)
    }
}

struct BlockScheduleTests {
    @Test("due on the first block, then every eighth")
    func firstThenEvery() {
        var schedule = BlockSchedule(every: 8)
        let due = (0..<17).map { _ in schedule.tick() }
        #expect(due.indices.filter { due[$0] } == [0, 8, 16])
    }

    @Test("a three-hour meeting of 4096-sample blocks never overflows")
    func longMeeting() {
        var schedule = BlockSchedule(every: 8)
        let blocks = 3 * 3600 * 16_000 / 4_096
        let checks = (0..<blocks).reduce(0) { count, _ in count + (schedule.tick() ? 1 : 0) }
        #expect(checks == (blocks + 7) / 8)
    }

    @Test("an interval below one checks every block")
    func degenerateInterval() {
        var schedule = BlockSchedule(every: 0)
        #expect(schedule.tick() && schedule.tick() && schedule.tick())
    }
}

struct HungarianTests {
    @Test("square matrix: the global optimum, not greedy")
    func square() {
        let cost: [[Double]] = [[4, 1, 3], [2, 0, 5], [3, 2, 2]]
        #expect(Hungarian.assign(cost) == [1, 0, 2])
    }

    @Test("more rows than columns leaves the worst row out")
    func tall() {
        let cost: [[Double]] = [[1, 9], [9, 1], [5, 5]]
        #expect(Hungarian.assign(cost) == [0, 1, nil])
    }

    @Test("more columns than rows")
    func wide() {
        let cost: [[Double]] = [[3, 1, 2]]
        #expect(Hungarian.assign(cost) == [1])
    }

    @Test("empty input")
    func empty() {
        #expect(Hungarian.assign([]) == [])
        #expect(Hungarian.assign([[]]) == [nil])
    }
}

struct WordBuilderTests {
    @Test("sub-word tokens join on the boundary marker, offset applied")
    func grouping() {
        let tokens = [
            TimedToken(text: "▁Bon", start: 0.0, end: 0.2, confidence: 0.9),
            TimedToken(text: "jour", start: 0.2, end: 0.4, confidence: 0.7),
            TimedToken(text: "<blank>", start: 0.4, end: 0.4, confidence: 1),
            TimedToken(text: "▁à", start: 0.5, end: 0.6, confidence: 0.95),
            TimedToken(text: " tous", start: 0.6, end: 0.9, confidence: 0.8),
            TimedToken(text: ".", start: 0.9, end: 0.95, confidence: 0.99),
        ]
        let words = WordBuilder.words(from: tokens, offset: 10)
        #expect(words.map(\.text) == ["Bonjour", "à", "tous."])
        #expect(words[0].start == 10.0 && words[0].end == 10.4)
        #expect(words[0].confidence == 0.7)
        #expect(words[2].end == 10.95)
    }
}

struct MeetingAppsTests {
    @Test("helpers map to their family; unknown apps are not meetings")
    func identify() {
        #expect(MeetingApps.identify("us.zoom.xos")?.name == "Zoom")
        #expect(MeetingApps.identify("com.microsoft.teams2")?.name == "Microsoft Teams")
        #expect(MeetingApps.identify("com.google.Chrome.helper")?.mainBundleID == "com.google.Chrome")
        #expect(MeetingApps.identify("com.google.Chrome.helper")?.isBrowser == true)
        #expect(MeetingApps.identify("com.apple.WebKit.GPU")?.name == "Safari")
        #expect(MeetingApps.identify("company.thebrowser.browser.helper")?.name == "Arc")
        #expect(MeetingApps.identify("com.apple.Music") == nil)
        #expect(MeetingApps.identify("com.google.Chromecast") == nil)
    }

    @Test("browser window titles that are calls")
    func titles() {
        #expect(MeetingApps.meetingService(inWindowTitle: "Meet – abc-defg-hij") == "Google Meet")
        #expect(MeetingApps.meetingService(inWindowTitle: "Meeting with Ada | Microsoft Teams") == "Microsoft Teams")
        #expect(MeetingApps.meetingService(inWindowTitle: "Inbox (3) - Gmail") == nil)
        #expect(MeetingApps.meetingService(inWindowTitle: "YouTube") == nil)
    }

    @Test("conferencing links in calendar events")
    func links() {
        #expect(MeetingApps.conferencingService(in: "Join: https://us02web.zoom.us/j/123456") == "Zoom")
        #expect(MeetingApps.conferencingService(in: "https://meet.google.com/abc-defg-hij") == "Google Meet")
        #expect(MeetingApps.conferencingService(in: "Room 4B") == nil)
    }

    @Test("participant lists are cleaned of markers, controls and the user")
    func participants() {
        let raw = ["Ada Lovelace (Host)", "Mute", "Bob (Guest)", "bob", "12", "Clément Veniard",
                   "Zoé (Hôte, moi)", "Grace Hopper"]
        #expect(ParticipantNames.clean(raw, excluding: ["clement veniard"]) == ["Ada Lovelace", "Bob", "Grace Hopper"])
    }

    @Test("headphone routes bypass echo cancellation")
    func route() {
        let fourCC = OutputRoute.fourCC
        #expect(OutputRoute.isHeadphones(transportType: fourCC("blue"), dataSource: nil))
        #expect(OutputRoute.isHeadphones(transportType: fourCC("bltn"), dataSource: fourCC("hdpn")))
        #expect(!OutputRoute.isHeadphones(transportType: fourCC("bltn"), dataSource: fourCC("ispk")))
        #expect(!OutputRoute.isHeadphones(transportType: fourCC("hdmi"), dataSource: nil))
        #expect(fourCC("bltn") == 0x626C_746E)
    }
}

struct MeetingModelTests {
    @Test("display names")
    func displayNames() {
        #expect(Speaker.me().displayName == "You")
        #expect(Speaker.others.displayName == "Others")
        #expect(Speaker(id: "S2").displayName == "Speaker 2")
        #expect(Speaker(id: "S2", name: "Ada", nameSource: .voicePrint).displayName == "Ada")
    }

    @Test("a meeting round-trips through JSON")
    func codable() throws {
        var meeting = Meeting(title: "Weekly", startedAt: Date(timeIntervalSince1970: 1_000))
        meeting.speakers = [.me(), Speaker(id: "S1")]
        meeting.segments = [TranscriptSegment(source: .system, speakerID: "S1", start: 1, end: 2, text: "Hi",
                                              words: [Word(text: "Hi", start: 1, end: 1.4, confidence: 0.9)])]
        let data = try JSONEncoder().encode(meeting)
        let decoded = try JSONDecoder().decode(Meeting.self, from: data)
        #expect(decoded.id == meeting.id)
        #expect(decoded.segments == meeting.segments)
        #expect(decoded.transcriptText == "[00:01] Speaker 1: Hi")
    }
}

/// FLU-12: the list row's summary fields and the French speaker labels.
struct MeetingSummaryFLU12Tests {
    @Test("the summary carries app, recap line, audio and speakers")
    func summaryFields() {
        var meeting = Meeting(title: "Point", appBundleID: "us.zoom.xos", startedAt: Date(timeIntervalSince1970: 0), keepAudio: true)
        meeting.speakers = [.me(), Speaker(id: "S1", name: "Camille", nameSource: .calendar), Speaker(id: "S2")]
        meeting.notes = MeetingNotes(
            recap: "Lancement fixé au 3 novembre. Le tutoriel passe à trois écrans.",
            nextSteps: [], decisions: [], openQuestions: [], generatedAt: Date(timeIntervalSince1970: 0), model: "m"
        )
        let summary = MeetingSummary(meeting)
        #expect(summary.appBundleID == "us.zoom.xos")
        #expect(summary.recapLine == "Lancement fixé au 3 novembre.")
        #expect(summary.keepAudio == true)
        #expect(summary.speakers?.count == 3)
    }

    @Test("an index written before FLU-12 still decodes")
    func legacyIndexDecodes() throws {
        let json = #"[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","title":"T","startedAt":0,"duration":60,"speakerNames":["You"],"hasNotes":false}]"#
        let summaries = try JSONDecoder().decode([MeetingSummary].self, from: Data(json.utf8))
        #expect(summaries.first?.appBundleID == nil)
        #expect(summaries.first?.speakers == nil)
    }

    @Test("a long recap is cut on a word")
    func recapLineIsBounded() {
        let long = String(repeating: "mot ", count: 60)
        let line = MeetingSummary.recapLine(from: long, limit: 20)
        #expect(line.hasSuffix("…"))
        #expect(line.count <= 21)
        #expect(MeetingSummary.recapLine(from: "") == "")
    }

    @Test("placeholders are French; names pass through")
    func frenchLabels() {
        #expect(Speaker.me().frenchDisplayName == "Vous")
        #expect(Speaker.others.frenchDisplayName == "Les autres")
        #expect(Speaker(id: "S2").frenchDisplayName == "Intervenant 2")
        #expect(Speaker(id: "S2", name: "Sophie").frenchDisplayName == "Sophie")
        #expect(Speaker(id: "S2").isUnnamed)
        #expect(!Speaker.me().isUnnamed)
        #expect(SpeakerLabel.french(displayName: "Speaker 3") == "Intervenant 3")
        #expect(SpeakerLabel.french(displayName: "Speakers") == "Speakers")
    }
}

/// FLU-22: telling the app two voices are one person.
struct SpeakerMergeTests {
    private func meeting() -> Meeting {
        var meeting = Meeting(title: "Point", startedAt: Date(timeIntervalSince1970: 0))
        meeting.speakers = [.me(named: "Clément"), Speaker(id: "S1", name: "Alice Martin", nameSource: .user), Speaker(id: "S2"), Speaker(id: "S3")]
        meeting.segments = [
            TranscriptSegment(source: .system, speakerID: "S1", start: 0, end: 2, text: "Bonjour."),
            TranscriptSegment(source: .system, speakerID: "S2", start: 2, end: 4, text: "Oui."),
            TranscriptSegment(source: .microphone, speakerID: "me", start: 4, end: 6, text: "Ok."),
            TranscriptSegment(source: .system, speakerID: "S3", start: 6, end: 8, text: "Merci."),
        ]
        return meeting
    }

    @Test("a voice renamed to an existing name finds that speaker, whatever the case or accents")
    func findsTheSamePerson() {
        let meeting = meeting()
        #expect(meeting.speaker(named: "alice  MARTIN", other: "S2")?.id == "S1")
        #expect(meeting.speaker(named: "clement", other: "S2")?.id == "me")
        #expect(meeting.speaker(named: "Alice Martin", other: "S1") == nil)
        #expect(meeting.speaker(named: "Bob", other: "S2") == nil)
        #expect(meeting.speaker(named: "  ", other: "S2") == nil)
    }

    @Test("merging moves every line and removes the extra voice")
    func mergesLines() {
        var meeting = meeting()
        meeting.mergeSpeaker("S2", into: "S1")
        #expect(meeting.speakers.map(\.id) == ["me", "S1", "S3"])
        #expect(meeting.segments.map(\.speakerID) == ["S1", "S1", "me", "S3"])
        meeting.mergeSpeaker("S3", into: "me")
        #expect(meeting.segments.map(\.speakerID) == ["S1", "S1", "me", "me"])
    }

    @Test("the user's own voice is never merged away")
    func keepsMe() {
        var meeting = meeting()
        meeting.mergeSpeaker("me", into: "S1")
        #expect(meeting.speakers.contains { $0.isMe })
        #expect(meeting.segments.map(\.speakerID) == ["S1", "S2", "me", "S3"])
    }
}
