// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Fluence",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Parakeet TDT as CoreML on the Neural Engine. Optional at runtime — Apple's
        // SpeechTranscriber remains the default and needs no dependency at all.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.5")
    ],
    targets: [
        // The dictionary is its own target so it can be tested directly, and because its
        // behaviour is a cross-platform contract: the Windows app reimplements this logic in
        // C#, and both sides run the same vectors in shared/dictionary-test-vectors.json.
        .target(
            name: "MurmurDictionary",
            path: "Sources/MurmurDictionary",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Notetaker (capture): the platform-neutral meeting logic — model, merge, echo dedupe,
        // word→speaker, naming, VAD segmentation. No AppKit or AVFoundation, so it is tested
        // directly, and its behaviour is shared with the Windows port through
        // shared/meeting-test-vectors.json.
        .target(
            name: "FluenceMeetingCore",
            path: "Sources/FluenceMeetingCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "Fluence",
            dependencies: [
                "MurmurDictionary",
                "FluenceMeetingCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/Fluence",
            swiftSettings: [
                .swiftLanguageMode(.v6)
            ]
        ),
        .testTarget(
            name: "MurmurDictionaryTests",
            dependencies: ["MurmurDictionary"],
            path: "Tests/MurmurDictionaryTests",
            resources: [.copy("dictionary-test-vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "FluenceMeetingCoreTests",
            dependencies: ["FluenceMeetingCore"],
            path: "Tests/FluenceMeetingCoreTests",
            resources: [.copy("meeting-test-vectors.json")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
