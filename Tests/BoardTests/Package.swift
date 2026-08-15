// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BoardTests",
    platforms: [.macOS(.v14)],
    dependencies: [.package(name: "WillagramsRules", path: "../..")],
    targets: [
        .testTarget(name: "BoardTests", dependencies: [.product(name: "WillagramsRules", package: "WillagramsRules")], path: "Cases"),
    ]
)
