// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Cribe",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/argmaxinc/argmax-oss-swift.git",
            revision: "97d09fd9790393579d2834e2bc098deb3e26bc06"
        ),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.15.5"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "3.0.1"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.5"),
    ],
    targets: [
        .binaryTarget(
            name: "CTranscribe",
            url: "https://github.com/handy-computer/transcribe.cpp/releases/download/v0.2.3/TranscribeCpp.xcframework.zip",
            checksum: "944be4d5232f39c99608f676a2ddda2516e0ed3c9fb6db50685ffa8d20a8b9c9"
        ),
        .target(
            name: "TranscribeCpp",
            dependencies: ["CTranscribe"],
            path: "Vendor/TranscribeCpp/Sources/TranscribeCpp",
            linkerSettings: [
                .linkedLibrary("c++"),
                .linkedLibrary("z"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Foundation"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
            ]
        ),
        .target(
            name: "CribeCore",
            dependencies: [
                .product(name: "WhisperKit", package: "argmax-oss-swift"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                "TranscribeCpp",
            ]
        ),
        .executableTarget(
            name: "Cribe",
            dependencies: [
                "CribeCore",
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
            ]
        ),
        .executableTarget(
            name: "CribeCLI",
            dependencies: ["CribeCore"]
        ),
        .testTarget(
            name: "CribeCoreTests",
            dependencies: ["CribeCore"]
        ),
        // Тесты самого приложения: стопка карточек живёт окнами, и её поведение
        // (вытеснение, освобождение окна) проверяется только здесь.
        .testTarget(
            name: "CribeAppTests",
            dependencies: ["Cribe"]
        ),
    ]
)
