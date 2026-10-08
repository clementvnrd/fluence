// swift-tools-version: 6.2
import PackageDescription

// The French dictation bench (FLU-24): every engine Fluence ships, run on the same audio
// the way the app runs it. See docs/SPEECH-MODELS.md.
let package = Package(
    name: "fbench",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.5"),
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", from: "1.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "fbench",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
            ],
            path: "Sources/fbench",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
