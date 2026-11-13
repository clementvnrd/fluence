import Testing

@testable import FluenceCore

/// FLU-128: the line under « Privé / Précis » says where the voice and the text really go.
struct TranscriptionRouteTests {
    private func line(
        local: ComparedEngine = .parakeet, cloud: CloudProvider? = nil, hasKey: Bool = false,
        compareMode: Bool = false, cleanup: CleanupLevel = .medium
    ) -> String {
        TranscriptionRoute.summary(local: local, cloud: cloud, hasKey: hasKey, compareMode: compareMode, cleanup: cleanup)
            .map { [$0.lead, $0.target].filter { !$0.isEmpty }.joined(separator: " ") }
            .joined(separator: " · ")
    }

    @Test func privateNamesTheLocalEngine() {
        #expect(line() == "Votre voix → Parakeet sur ce Mac · Correction sur ce Mac")
        #expect(line(local: .apple) == "Votre voix → Apple sur ce Mac · Correction sur ce Mac")
    }

    @Test func preciseWithKeyNamesTheProviderAndTheFallback() {
        #expect(line(cloud: .elevenLabs, hasKey: true) == "Votre voix → ElevenLabs · Correction sur ce Mac · Secours Parakeet")
        // Parakeet not on disk yet: Apple is what CloudEngine wraps, so Apple is the fallback.
        #expect(line(local: .apple, cloud: .elevenLabs, hasKey: true).hasSuffix("Secours Apple"))
        let parts = TranscriptionRoute.summary(local: .whisper, cloud: .elevenLabs, hasKey: true, compareMode: false, cleanup: .light)
        #expect(parts.map(\.isCloud) == [true, false, false])
        #expect(parts.last?.target == "Whisper")
    }

    @Test func preciseWithoutKeyStaysOnTheMacAndSaysSo() {
        #expect(line(cloud: .elevenLabs) == "Votre voix → Parakeet sur ce Mac · Aucune clé ElevenLabs · Correction sur ce Mac")
        #expect(TranscriptionRoute.summary(local: .parakeet, cloud: .elevenLabs, hasKey: false, compareMode: false, cleanup: .medium)
            .allSatisfy { !$0.isCloud })
    }

    // A4-15: the dictionary's corrections still apply at level « Aucun ».
    @Test func levelNoneSaysOnlyTheDictionaryCorrects() {
        #expect(line(cleanup: .none) == "Votre voix → Parakeet sur ce Mac · Dictionnaire seul")
        #expect(line(cloud: .elevenLabs, hasKey: true, cleanup: .none) == "Votre voix → ElevenLabs · Dictionnaire seul · Secours Parakeet")
    }

    @Test func compareModeNeverSendsToTheCloud() {
        #expect(line(cloud: .elevenLabs, hasKey: true, compareMode: true) == "Votre voix → Mode comparaison · Correction sur ce Mac")
    }

    /// FLU-140: the Précis card's amber line and « Secours » follow what is really sent.
    @Test func audioIsSentOnlyWithAKeyAndOutsideCompareMode() {
        #expect(TranscriptionRoute.sentTo(cloud: .elevenLabs, hasKey: true, compareMode: false) == .elevenLabs)
        #expect(TranscriptionRoute.sentTo(cloud: .elevenLabs, hasKey: true, compareMode: true) == nil)
        #expect(TranscriptionRoute.sentTo(cloud: .elevenLabs, hasKey: false, compareMode: false) == nil)
        #expect(TranscriptionRoute.sentTo(cloud: nil, hasKey: true, compareMode: false) == nil)
    }

    /// FLU-134: the amber line used to name only the audio; the dictionary's terms (often names) go too.
    @Test func sentNoteNamesTheAudioAndTheDictionary() {
        let note = TranscriptionRoute.sentNote(.elevenLabs)
        #expect(note.contains("audio") && note.contains("dictionnaire") && note.contains("ElevenLabs"))
    }
}
