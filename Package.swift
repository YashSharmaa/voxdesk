// swift-tools-version: 6.0
// Toolchains before Swift 6.2: Whisper only. Package@swift-6.2.swift adds the Parakeet engine (FluidAudio), which
// needs 6.2 package traits to leave out FluidAudio's text-to-speech data.
import PackageDescription

let package = Package(
    name: "VoxDesk",
    platforms: [.macOS(.v14)],
    dependencies: [
        // WhisperKit lives in Argmax's renamed open-source repo (MIT).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        // Global hotkeys and the recorder view (MIT).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "3.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoxDesk",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/VoxDesk",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
