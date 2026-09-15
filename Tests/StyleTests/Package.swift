// swift-tools-version: 6.0
import PackageDescription

// A standalone package, deliberately.
//
// The root `Package.swift` is protected by MAP.md, so the style lane cannot
// declare a test target in it, and `Tests/WillagramsRulesTests/` is protected
// too. SwiftPM ignores directories the root manifest does not name, so this
// nests without affecting `swift test` at the repo root.
//
// Run with: swift test --package-path Tests/StyleTests
let package = Package(
    name: "StyleTests",
    platforms: [.macOS(.v14)],
    targets: [
        // The real `DesignTokens.swift` (and `BrandFonts.swift`, which it
        // names), symlinked per file, so `ScreenMargin.value` runs here
        // rather than being read as source. Both build for macOS.
        .target(name: "StyleKit", path: "StyleSrc"),
        .testTarget(name: "StyleTests", dependencies: ["StyleKit"], path: "Cases"),
    ]
)
