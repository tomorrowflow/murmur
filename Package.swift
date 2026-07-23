// swift-tools-version: 5.9
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "Murmur",
            targets: ["Murmur"]),
        .executable(
            name: "TestDownload",
            targets: ["TestDownload"]),
        .executable(
            name: "ListModels",
            targets: ["ListModels"]),
        .executable(
            name: "DeleteModels",
            targets: ["DeleteModels"]),
        .executable(
            name: "DeleteModel",
            targets: ["DeleteModel"]),
        .executable(
            name: "ValidateModels",
            targets: ["ValidateModels"]),
        .executable(
            name: "TestTranscription",
            targets: ["TestTranscription"]),
        .executable(
            name: "TestLiveTranscription",
            targets: ["TestLiveTranscription"]),
        .executable(
            name: "TestSentenceSplitter",
            targets: ["TestSentenceSplitter"]),
        .executable(
            name: "TestMediaRemote",
            targets: ["TestMediaRemote"]),
        .executable(
            name: "TestAudioActivity",
            targets: ["TestAudioActivity"]),
        .executable(
            name: "RecordScreen",
            targets: ["RecordScreen"]),
        .executable(
            name: "TranscribeVideo",
            targets: ["TranscribeVideo"]),
        .library(
            name: "SharedModels",
            targets: ["SharedModels"])
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", exact: "1.8.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.13.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.7.9")
    ],
    targets: [
        .target(
            name: "ObjCExceptionCatcher",
            path: "ObjCSupport"),
        .target(
            name: "SharedModels",
            dependencies: ["WhisperKit", "FluidAudio", "ObjCExceptionCatcher"],
            path: "SharedSources"),
        .executableTarget(
            name: "Murmur",
            dependencies: ["KeyboardShortcuts", "WhisperKit", "SharedModels", "FluidAudio"],
            path: "Sources",
            exclude: ["Assets.xcassets", "AppIcon.icns"]),
        .executableTarget(
            name: "TestDownload",
            dependencies: ["WhisperKit", "SharedModels"],
            path: "tests/test-download"),
        .executableTarget(
            name: "ListModels",
            dependencies: ["WhisperKit", "SharedModels"],
            path: "tools/list-models"),
        .executableTarget(
            name: "DeleteModels",
            dependencies: ["SharedModels"],
            path: "tools/delete-models"),
        .executableTarget(
            name: "DeleteModel",
            dependencies: ["SharedModels"],
            path: "tools/delete-model"),
        .executableTarget(
            name: "ValidateModels",
            dependencies: ["WhisperKit", "SharedModels"],
            path: "tools/validate-models"),
        .executableTarget(
            name: "TestTranscription",
            dependencies: ["WhisperKit", "SharedModels"],
            path: "tests/test-transcription"),
        .executableTarget(
            name: "TestLiveTranscription",
            dependencies: ["WhisperKit", "SharedModels"],
            path: "tests/test-live-transcription"),
        .executableTarget(
            name: "TestSentenceSplitter",
            dependencies: ["SharedModels"],
            path: "tests/test-sentence-splitter"),
        .executableTarget(
            name: "TestMediaRemote",
            dependencies: [],
            path: "tests/test-media-remote"),
        .executableTarget(
            name: "TestAudioActivity",
            dependencies: [],
            path: "tests/test-audio-activity"),
        .executableTarget(
            name: "RecordScreen",
            dependencies: [],
            path: "tools/record-screen"),
        .executableTarget(
            name: "TranscribeVideo",
            dependencies: [],
            path: "tools/transcribe-video"),
        .testTarget(
            name: "SharedModelsTests",
            dependencies: ["SharedModels"],
            path: "tests/SharedModelsTests")
    ]
)
