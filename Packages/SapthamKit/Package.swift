// swift-tools-version: 6.0
// SapthamKit — the caption engine, with no user interface.
//
//   SapthamCore      audio-source and transcriber contracts, the caption
//                    feed the UI observes, Apple on-device speech, microphone.
//                    iOS + macOS.
//   SapthamMacAudio  macOS-only sources: call audio relayed from iPhone, one
//                    app's audio, or all system audio (Core Audio process taps).
//   SapthamSigns     sign-language dictionary packs: read, verify, look up a
//                    word (ADR 0003). Independent of SapthamCore on purpose.
//   SignPackBuilder  builds a pack from a content folder; used by the
//                    `signpack` command-line tool, never by the apps.
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
        .library(name: "SapthamSigns", targets: ["SapthamSigns"]),
    ],
    targets: [
        .target(name: "SapthamCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "SapthamMacAudio", dependencies: ["SapthamCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "SapthamSigns", swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "SignPackBuilder", dependencies: ["SapthamSigns"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
        .executableTarget(name: "signpack", dependencies: ["SignPackBuilder", "SapthamSigns"],
                          swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SapthamCoreTests", dependencies: ["SapthamCore"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SapthamSignsTests", dependencies: ["SapthamSigns"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SignPackBuilderTests", dependencies: ["SignPackBuilder", "SapthamSigns"],
                    swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
