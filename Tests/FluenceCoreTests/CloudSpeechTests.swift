import Foundation
import Testing

@testable import FluenceCore

/// FLU-113: the opt-in cloud engine — the requests sent, the answers read (sample bodies from
/// the providers' docs), the fallback to the local engine, the audio file and the key store.
struct CloudSpeechTests {
    private func field(_ name: String, _ value: String) -> String {
        "--B\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
    }

    private func body(_ request: URLRequest) throws -> String {
        String(decoding: try #require(request.httpBody), as: UTF8.self)
    }

    // MARK: - Requests

    @Test func mistralTranscriptionRequest() throws {
        let request = CloudRequest.transcription(
            provider: .mistral, key: "k-123", wav: Data("RIFF".utf8), language: "fr",
            terms: ["Fluence", "Clément Dupont"], boundary: "B"
        )
        #expect(request.url?.absoluteString == "https://api.mistral.ai/v1/audio/transcriptions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k-123")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=B")
        let text = try body(request)
        #expect(text.contains(field("model", "voxtral-mini-transcribe-3-0")))
        #expect(text.contains(field("language", "fr")))
        #expect(text.contains(field("context_bias", "Fluence")))
        #expect(text.contains(field("context_bias", "Clément Dupont")))
        #expect(text.contains("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\nRIFF\r\n"))
        #expect(text.hasSuffix("--B--\r\n"))
        // The key goes in the header only.
        #expect(!text.contains("k-123"))
    }

    @Test func elevenLabsTranscriptionRequest() throws {
        let request = CloudRequest.transcription(
            provider: .elevenLabs, key: "xi-9", wav: Data("RIFF".utf8), language: "fr",
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
        for provider in CloudProvider.allCases {
            let text = try body(CloudRequest.transcription(provider: provider, key: "k", wav: Data(), language: nil, terms: [], boundary: "B"))
            #expect(!text.contains("name=\"language"))
            #expect(!text.contains("name=\"context_bias\""))
            #expect(!text.contains("name=\"keyterms\""))
        }
    }

    @Test func termsTheProviderWouldRefuseAreLeftOut() {
        let terms = ["Fluence", "a<b", "x[1]", "back\\slash", String(repeating: "x", count: 51), "un deux trois quatre cinq six", "  ", "un deux trois quatre cinq"]
        #expect(CloudRequest.terms(terms, for: .elevenLabs) == ["Fluence", "un deux trois quatre cinq"])
        // Mistral documents no such rule: only blanks go.
        #expect(CloudRequest.terms(terms, for: .mistral).count == terms.count - 1)
    }

    @Test func termsAreCappedAtTheProviderLimit() {
        let many = (0..<150).map { "terme\($0)" }
        for provider in CloudProvider.allCases {
            #expect(CloudRequest.terms(many, for: provider) == Array(many.prefix(100)))
        }
    }

    @Test func cleanupRequest() throws {
        let request = CloudRequest.cleanup(key: "k-1", instructions: "Règles", prompt: "Nettoie : texte")
        #expect(request.url?.absoluteString == "https://api.mistral.ai/v1/chat/completions")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer k-1")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let data = try #require(request.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["model"] as? String == "mistral-small-2603")
        #expect(json["temperature"] as? Double == 0.1)
        #expect(json["reasoning_effort"] as? String == "none")
        let messages = try #require(json["messages"] as? [[String: String]])
        #expect(messages == [["role": "system", "content": "Règles"], ["role": "user", "content": "Nettoie : texte"]])
    }

    // MARK: - Answers

    @Test func mistralTranscript() throws {
        let sample = #"{"model":"voxtral-mini-transcribe-3","text":"Thanks for calling Northwind Support.","language":null,"segments":[],"usage":{"prompt_audio_seconds":34}}"#
        #expect(try CloudResponse.transcript(status: 200, body: Data(sample.utf8)) == "Thanks for calling Northwind Support.")
    }

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
        #expect(throws: CloudError.badKey) { try CloudResponse.cleanup(status: 401, body: body) }
    }

    @Test func aSuccessWithoutTextIsMalformed() {
        #expect(throws: CloudError.malformed) { try CloudResponse.transcript(status: 200, body: Data("{}".utf8)) }
        #expect(throws: CloudError.malformed) { try CloudResponse.transcript(status: 200, body: Data("<html>".utf8)) }
        #expect(throws: CloudError.malformed) { try CloudResponse.cleanup(status: 200, body: Data(#"{"choices":[]}"#.utf8)) }
    }

    @Test func cleanupAnswer() throws {
        let plain = #"{"id":"cmpl-1","object":"chat.completion","model":"mistral-small-2603","choices":[{"index":0,"message":{"role":"assistant","content":"  Bonjour.\n"},"finish_reason":"stop"}]}"#
        #expect(try CloudResponse.cleanup(status: 200, body: Data(plain.utf8)) == "Bonjour.")
        // Reasoning models may answer with chunks: only the text ones count.
        let chunks = #"{"choices":[{"index":0,"message":{"role":"assistant","content":[{"type":"thinking","thinking":[{"type":"text","text":"hmm"}]},{"type":"text","text":"Bonjour."}]},"finish_reason":"stop"}]}"#
        #expect(try CloudResponse.cleanup(status: 200, body: Data(chunks.utf8)) == "Bonjour.")
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
        #expect(!keys.has(.mistral))
        try keys.save("  sk-1\n", for: .mistral)
        #expect(try keys.key(for: .mistral) == "sk-1")
        #expect(try store.read("mistral") == "sk-1")
        #expect(keys.has(.mistral))
        #expect(!keys.has(.elevenLabs))
        try keys.save("sk-2", for: .mistral)
        #expect(try keys.key(for: .mistral) == "sk-2")
        #expect(throws: CloudKeys.Failure.empty) { try keys.save(" \n", for: .elevenLabs) }
        try keys.remove(.mistral)
        #expect(try keys.key(for: .mistral) == nil)
        #expect(try store.read("mistral") == nil)
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
