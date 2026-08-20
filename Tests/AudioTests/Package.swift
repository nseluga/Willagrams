// swift-tools-version: 6.0
import PackageDescription

// A standalone package, deliberately — the root `Package.swift` is protected
// by MAP.md. SwiftPM ignores directories the root manifest does not name, so
// this nests without affecting `swift test` at the repo root.
//
// Run with: swift test --package-path Tests/AudioTests
let package = Package(
    name: "AudioTests",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "Audio", path: "AudioSrc"),
        .testTarget(name: "AudioTests", dependencies: ["Audio"], path: "Cases"),
    ]
)
