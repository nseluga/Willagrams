// swift-tools-version: 6.0
// A standalone package, deliberately.
//
// The root `Package.swift` is protected by MAP.md, so the settings lane cannot
// declare a test target in it, and `Tests/WillagramsRulesTests/` is protected
// too. SwiftPM ignores directories the root manifest does not name, so this
// nests without affecting `swift test` at the repo root.
//
// Run with: swift test --package-path Tests/SettingsTests
import PackageDescription

let package = Package(
    name: "SettingsTests",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(
            name: "Settings",
            dependencies: [.product(name: "WillagramsRules", package: "Willagrams")],
            path: "SettingsSrc"
        ),
        .testTarget(name: "SettingsTests", dependencies: ["Settings"], path: "Cases"),
    ]
)
