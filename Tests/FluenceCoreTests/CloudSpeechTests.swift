import Foundation
import Testing

@testable import FluenceCore

/// FLU-113: the opt-in cloud engine — the request sent, the answers read (sample bodies from
/// ElevenLabs' docs), the fallback to the local engine, the audio file and the key store.
struct CloudSpeechTests {
    private func field(_ name: String, _ value: String) -> String {
        "--B\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
    }

    private func body(_ request: URLRequest) throws -> String {
        String(decoding: try #require(request.httpBody), as: UTF8.self)
    }

    // MARK: - Requests

    @Test func elevenLabsTranscriptionRequest() throws {
        let request = CloudRequest.transcription(
            key: "xi-9", wav: Data("RIFF".utf8), language: "fr",
            terms: ["Fluence"], boundary: "B"
        )
        #expect(request.url?.absoluteString == "https://api.elevenlabs.io/v1/speech-to-text")
        #expect(request.value(forHTTPHeaderField: "xi-api-key") == "xi-9")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
        let text = try body(request)
        #expect(text.contains(field("model_id", "scribe_v3")))
        #expect(text.contains(field("language_code", "fr")))
        #expect(text.contains(field("keyterms", "Fluence")))
        #expect(text.contains(field("tag_audio_events", "false")))
        #expect(text.contains("name=\"file\"; filename=\"audio.wav\""))
        #expect(!text.contains("xi-9"))
    }

    @Test func autoLanguageLetsTheProviderDetect() throws {
        let text = try body(CloudRequest.transcription(key: "k", wav: Data(), language: nil, terms: [], boundary: "B"))
        #expect(!text.contains("name=\"language"))
        #expect(!text.contains("name=\"keyterms\""))
    }

    @Test func termsTheProviderWouldRefuseAreLeftOut() {
        let terms = ["Fluence", "a<b", "x[1]", "back\\slash", String(repeating: "x", count: 51), "un deux trois quatre cinq six", "  ", "un deux trois quatre cinq"]
        #expect(CloudRequest.terms(terms) == ["Fluence", "un deux trois quatre cinq"])
    }

    @Test func termsAreCappedAtTheProviderLimit() {
        let many = (0..<150).map { "terme\($0)" }
        #expect(CloudRequest.terms(many) == Array(many.prefix(100)))
    }

    // MARK: - Answers

    @Test func elevenLabsTranscript() throws {
        let sample = #"{"language_code":"en","language_probability":0.98,"text":"Hello world!","words":[{"end":0.5,"logprob":-0.124,"start":0,"text":"Hello","type":"word"}]}"#
        #expect(try CloudResponse.transcript(status: 200, body: Data(sample.utf8)) == "Hello world!")
    }

    @Test func errorsAreReadFromTheStatusAlone() {
        let body = Data(#"{"detail":{"status":"invalid_api_key","message":"Invalid API key"}}"#.utf8)
        #expect(throws: CloudError.badKey) { try CloudResponse.transcript(status: 401, body: body) }
        #expect(throws: CloudError.badKey) { try CloudResponse.transcript(status: 403, body: body) }
        #expect(throws: CloudError.rateLimited) { try CloudResponse.transcript(status: 429, body: body) }
        #expect(throws: CloudError.server(503)) { try CloudResponse.transcript(status: 503, body: body) }
        #expect(throws: CloudError.rejected(422)) { try CloudResponse.transcript(status: 422, body: body) }
    }

    @Test func aSuccessWithoutTextIsMalformed() {
        #expect(throws: CloudError.malformed) { try CloudResponse.transcript(status: 200, body: Data("{}".utf8)) }
        #expect(throws: CloudError.malformed) { try CloudResponse.transcript(status: 200, body: Data("<html>".utf8)) }
    }

    @Test func errorKindsAreFixedWords() {
        #expect(CloudError.server(503).kind == "server 503")
        #expect(CloudError.badKey.kind == "bad key")
        #expect(CloudError.timedOut.kind == "timed out")
    }

    // MARK: - Fallback

    @Test func theWaitGrowsWithTheAudioAndIsCapped() {
        #expect(CloudFallback.deadline(audioSeconds: 0) == 2.5)
        #expect(abs(CloudFallback.deadline(audioSeconds: 10) - 3.5) < 1e-9)
        #expect(CloudFallback.deadline(audioSeconds: 55) == 8)
        #expect(CloudFallback.deadline(audioSeconds: 600) == 8)
    }

    @Test func theCloudWinsWhenItAnswersInTime() {
        #expect(CloudFallback.choose(cloud: .text("nuage"), local: nil) == .cloud("nuage"))
        #expect(CloudFallback.choose(cloud: .text("nuage"), local: "local") == .cloud("nuage"))
    }

    @Test func theLocalTextWinsWhenTheCloudFailsOrIsLate() {
        #expect(CloudFallback.choose(cloud: .failed(.network), local: "local") == .local("local", because: .network))
        #expect(CloudFallback.choose(cloud: nil, local: "local") == .local("local", because: .timedOut))
        // The cloud heard nothing where the Mac heard words: the words, without a notice.
        #expect(CloudFallback.choose(cloud: .text("  "), local: "local") == .local("local", because: nil))
    }

    @Test func withoutLocalTextOnlyTheCloudCounts() {
        #expect(CloudFallback.choose(cloud: nil, local: nil) == .failed(.timedOut))
        #expect(CloudFallback.choose(cloud: nil, local: " ") == .failed(.timedOut))
        #expect(CloudFallback.choose(cloud: .failed(.server(500)), local: nil) == .failed(.server(500)))
        #expect(CloudFallback.choose(cloud: .text(""), local: nil) == .cloud(""))
    }

    @Test func theCapsuleSaysWhyInAFewWords() {
        let nbsp = "\u{00A0}"
        #expect(CloudFallback.notice(.network, local: "Parakeet") == "Hors ligne\(nbsp): Parakeet")
        #expect(CloudFallback.notice(.noKey, local: "Parakeet") == "Aucune clé\(nbsp): Parakeet")
        #expect(CloudFallback.notice(.badKey, local: "Apple") == "Clé refusée\(nbsp): Apple")
        #expect(CloudFallback.notice(.timedOut, local: "Parakeet") == "Cloud trop lent\(nbsp): Parakeet")
        #expect(CloudFallback.notice(.server(500), local: "Parakeet") == "Cloud indisponible\(nbsp): Parakeet")
        #expect(CloudFallback.notice(.rateLimited, local: "Parakeet") == "Cloud indisponible\(nbsp): Parakeet")
    }

    // MARK: - FLU-129: who wrote the text

    @Test func theBadgeNamesWhoWroteTheText() {
        #expect(CloudFallback.Choice.cloud("nuage").writer == .cloud)
        #expect(CloudFallback.Choice.local("local", because: .network).writer == .mac)
        #expect(CloudFallback.Choice.local("local", because: nil).writer == .mac)
        #expect(CloudFallback.Choice.failed(.timedOut).writer == nil)
    }

    @Test func theCapsuleStaysLongerOnlyForABadgeAlone() {
        #expect(CloudFallback.badgeHold(writer: .cloud, messageFollows: false) == 0.4)
        #expect(CloudFallback.badgeHold(writer: .mac, messageFollows: false) == 0.4)
        // The fallback's notice shows the badge for its own 3 s.
        #expect(CloudFallback.badgeHold(writer: .mac, messageFollows: true) == 0)
        // Privé mode: no badge, today's timing.
        #expect(CloudFallback.badgeHold(writer: nil, messageFollows: false) == 0)
    }

    // MARK: - Audio

    @Test func wavIsSixteenBitMonoWithItsHeader() {
        let wav = [UInt8](WAV.encode([0, 1, -1, 2, -2], sampleRate: 16_000))
        #expect(wav.count == 44 + 10)
        func u32(_ at: Int) -> UInt32 { (0..<4).reduce(0) { $0 | UInt32(wav[at + $1]) << (8 * $1) } }
        func u16(_ at: Int) -> UInt16 { UInt16(wav[at]) | UInt16(wav[at + 1]) << 8 }
        func i16(_ at: Int) -> Int16 { Int16(bitPattern: u16(at)) }
        #expect(String(decoding: wav[0..<4], as: UTF8.self) == "RIFF")
        #expect(u32(4) == 36 + 10)
        #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(u32(16) == 16)
        #expect(u16(20) == 1)  // PCM
        #expect(u16(22) == 1)  // mono
        #expect(u32(24) == 16_000)
        #expect(u32(28) == 32_000)
        #expect(u16(32) == 2)
        #expect(u16(34) == 16)
        #expect(String(decoding: wav[36..<40], as: UTF8.self) == "data")
        #expect(u32(40) == 10)
        #expect([i16(44), i16(46), i16(48), i16(50), i16(52)] == [0, 32_767, -32_767, 32_767, -32_767])
    }

    // MARK: - Keys

    @Test func keysAreTrimmedStoredAndForgotten() throws {
        let store = InMemorySecretStore()
        let keys = CloudKeys(store: store)
        #expect(!keys.has(.elevenLabs))
        try keys.save("  xi-1\n", for: .elevenLabs)
        #expect(try keys.key(for: .elevenLabs) == "xi-1")
        #expect(try store.read("elevenlabs") == "xi-1")
        #expect(keys.has(.elevenLabs))
        try keys.save("xi-2", for: .elevenLabs)
        #expect(try keys.key(for: .elevenLabs) == "xi-2")
        #expect(throws: CloudKeys.Failure.empty) { try keys.save(" \n", for: .elevenLabs) }
        try keys.remove(.elevenLabs)
        #expect(try keys.key(for: .elevenLabs) == nil)
        #expect(try store.read("elevenlabs") == nil)
    }

    @Test func aRemovedProviderReadsAsOff() {
        // « mistral » may be stored by a dev build: the setting then reads as off.
        #expect(CloudProvider(rawValue: "mistral") == nil)
        #expect(CloudProvider(rawValue: "elevenlabs") == .elevenLabs)
    }

    @Test func aKeyIsReadFromTheStoreOnce() throws {
        let store = InMemorySecretStore()
        try store.write("xi-1", account: "elevenlabs")
        let keys = CloudKeys(store: store)
        #expect(try keys.key(for: .elevenLabs) == "xi-1")
        try store.delete("elevenlabs")
        // Cached: the Keychain is not asked again at every key-down.
        #expect(try keys.key(for: .elevenLabs) == "xi-1")
    }
}
