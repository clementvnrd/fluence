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
