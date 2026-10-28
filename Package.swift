// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Fluence",
    platforms: [.macOS("26.0")],
    dependencies: [
        // Parakeet on CoreML (FluidAudio), an optional engine: Apple's own speech engine
        // needs no package at all.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.5"),
        // OpenAI Whisper as CoreML on Apple Silicon (WhisperKit). Optional at runtime too:
        // its model is downloaded the first time Whisper is chosen.
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
        // In-app updates (FLU-26): checks the feed in Info.plist, verifies the EdDSA signature
        // and the code signature, installs on quit or on the user's click. A binary framework,
        // embedded in Contents/Frameworks by the Makefile.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        // Dictionary corrections and bias phrases. A target of its own so it is tested alone:
        // its behaviour is specified by Tests/FluenceDictionaryTests/dictionary-test-vectors.json.
        .target(
            name: "FluenceDictionary",
            path: "Sources/FluenceDictionary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Notetaker (capture): the platform-neutral meeting logic — model, merge, echo dedupe,
        // word→speaker, naming, VAD segmentation. No AppKit or AVFoundation, so it is tested
        // directly, and its behaviour is specified by
        // Tests/FluenceMeetingCoreTests/meeting-test-vectors.json.
        .target(
            name: "FluenceMeetingCore",
            path: "Sources/FluenceMeetingCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Logic the app depends on that needs no microphone, Keychain or window — formats,
        // policies, signal maths. Its own target so it runs under `swift test`; the app
        // target can only be typechecked without Xcode, never exercised.
        .target(
            name: "FluenceCore",
            path: "Sources/FluenceCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Fluence",
            dependencies: [
                "FluenceDictionary",
                "FluenceMeetingCore",
                "FluenceNotesCore",
                "FluenceCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/Fluence",
            swiftSettings: [
                .swiftLanguageMode(.v6),
            ]
        ),
        // The Notetaker's notes logic (chunking, prompts, merging, Markdown, retention),
        // kept free of the app and of Foundation Models so it runs under `swift test`.
        .target(
            name: "FluenceNotesCore",
            path: "Sources/FluenceNotesCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FluenceNotesCoreTests",
            dependencies: ["FluenceNotesCore"],
            path: "Tests/FluenceNotesCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FluenceDictionaryTests",
            dependencies: ["FluenceDictionary"],
            path: "Tests/FluenceDictionaryTests",
            resources: [
                .copy("dictionary-test-vectors.json"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FluenceMeetingCoreTests",
            dependencies: ["FluenceMeetingCore"],
            path: "Tests/FluenceMeetingCoreTests",
            resources: [.copy("meeting-test-vectors.json"), .copy("transcript-import-vectors.json"), .copy("speaker-consolidation-vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FluenceCoreTests",
            dependencies: ["FluenceCore"],
            path: "Tests/FluenceCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
