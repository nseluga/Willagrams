// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WillagramsRules",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "WillagramsRules", targets: ["WillagramsRules"]),
    ],
    targets: [
        .target(name: "WillagramsRules", resources: [.process("Resources")]),
        .testTarget(name: "WillagramsRulesTests", dependencies: ["WillagramsRules"], resources: [.process("Fixtures")]),
    ]
)
