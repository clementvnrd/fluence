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

    @Test func levelNoneSaysThereIsNoCorrection() {
        #expect(line(cleanup: .none) == "Votre voix → Parakeet sur ce Mac · Sans correction")
        #expect(line(cloud: .elevenLabs, hasKey: true, cleanup: .none) == "Votre voix → ElevenLabs · Sans correction · Secours Parakeet")
    }

    @Test func compareModeNeverSendsToTheCloud() {
        #expect(line(cloud: .elevenLabs, hasKey: true, compareMode: true) == "Votre voix → Mode comparaison · Correction sur ce Mac")
    }
}
