// swift-tools-version: 6.2
// Swift 6.2 and later (Xcode 26): both engines. FluidAudio's traits let VoxDesk take its speech recognition
// only, leaving out the text-to-speech code and its data files (some are GPL-derived), diarization and the
// prebuilt text normaliser. Package.swift is the Whisper-only manifest for older toolchains.
import PackageDescription

let package = Package(
    name: "VoxDesk",
    platforms: [.macOS(.v14)],
    dependencies: [
        // WhisperKit lives in Argmax's renamed open-source repo (MIT).
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift.git", exact: "1.1.1"),
        // Parakeet TDT on Core ML (Apache-2.0). Pinned exactly: the ASR API used was read from this tag.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.18.2", traits: []),
        // Global hotkeys and the recorder view (MIT).
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "3.1.0"),
    ],
    targets: [
        .executableTarget(
            name: "VoxDesk",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            path: "Sources/VoxDesk",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
