// swift-tools-version: 6.2
import PackageDescription

// The meeting speaker bench (FLU-33): Fluence's real speaker pipeline — FluidAudio's offline
// diarizer with the app's configuration, then FluenceMeetingCore's SpeakerConsolidation —
// run on public AMI meetings and scored on DER and speaker count. See README.md.
//
// `Sources/FluenceMeetingCore` is a symlink to the app's own `Sources/FluenceMeetingCore`:
// the bench compiles the code the app ships, never a copy. Build out of the repo:
//   swift build --scratch-path ~/Library/Caches/FluenceBuild/bench-meetings
let package = Package(
    name: "mbench",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Exactly the version the app resolves (root Package.resolved). Move both together.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5"),
    ],
    targets: [
        .target(
            name: "FluenceMeetingCore",
            path: "Sources/FluenceMeetingCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Scoring and sweeps: no FluidAudio, no audio, so it is unit tested.
        .target(
            name: "MeetingBench",
            dependencies: ["FluenceMeetingCore"],
            path: "Sources/MeetingBench",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "mbench",
            dependencies: [
                "MeetingBench",
                "FluenceMeetingCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "Sources/mbench",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MeetingBenchTests",
            dependencies: ["MeetingBench", "FluenceMeetingCore"],
            path: "Tests/MeetingBenchTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
