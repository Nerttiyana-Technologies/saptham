// swift-tools-version: 6.0
// SapthamKit — the caption engine, with no user interface.
//
//   SapthamCore      audio-source and transcriber contracts, the caption
//                    feed the UI observes, Apple on-device speech, microphone.
//                    iOS + macOS.
//   SapthamMacAudio  macOS-only sources: call audio relayed from iPhone, one
//                    app's audio, or all system audio (Core Audio process taps).
//
// Apple frameworks only. Every third-party addition needs its licence named
// and its notice added in the same change.
import PackageDescription

let package = Package(
    name: "SapthamKit",
    platforms: [.macOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "SapthamCore", targets: ["SapthamCore"]),
        .library(name: "SapthamMacAudio", targets: ["SapthamMacAudio"]),
    ],
    targets: [
        .target(name: "SapthamCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "SapthamMacAudio", dependencies: ["SapthamCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SapthamCoreTests", dependencies: ["SapthamCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
