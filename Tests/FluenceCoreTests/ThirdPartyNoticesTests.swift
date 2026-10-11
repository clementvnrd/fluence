import Foundation
import Testing

/// FLU-68: the notices shipped in the app are generated from the package versions pinned in
/// `Package.resolved` (`make notices`). When a dependency moves and the file is not regenerated,
/// the app would credit a version it no longer contains.
struct ThirdPartyNoticesTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    private struct Resolved: Decodable {
        struct Pin: Decodable {
            struct State: Decodable { let version: String }
            let identity: String
            let state: State
        }
        let pins: [Pin]
    }

    @Test func everyPinnedPackageIsCreditedAtItsPinnedVersion() throws {
        let resolved = try JSONDecoder().decode(
            Resolved.self, from: Data(contentsOf: Self.root.appendingPathComponent("Package.resolved")))
        let notices = try String(contentsOf: Self.root.appendingPathComponent("Resources/THIRD-PARTY-NOTICES.txt"), encoding: .utf8)
        let headings = notices.split(separator: "\n").map { $0.lowercased() }

        #expect(!resolved.pins.isEmpty)
        for pin in resolved.pins {
            // A heading looks like "fluidaudio 0.17.5" or "whisperkit (argmax-oss-swift) 1.1.0".
            #expect(
                headings.contains { $0.contains(pin.identity.lowercased()) && $0.hasSuffix(" " + pin.state.version) },
                "\(pin.identity) \(pin.state.version) is missing from THIRD-PARTY-NOTICES.txt: run `make notices`")
        }
    }

    @Test func theModelsFluenceDownloadsAreCredited() throws {
        let notices = try String(contentsOf: Self.root.appendingPathComponent("Resources/THIRD-PARTY-NOTICES.txt"), encoding: .utf8)
        for model in ["parakeet-ultra-coreml", "parakeet-ctc-110m-coreml", "parakeet-tdt-0.6b-v3-coreml",
                      "speaker-diarization-coreml", "silero-vad-coreml", "whisperkit-coreml"] {
            #expect(notices.contains(model), "\(model) is downloaded by Fluence and must be credited")
        }
    }
}
