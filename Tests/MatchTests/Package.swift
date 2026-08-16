// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MatchTests",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(
            name: "Match",
            dependencies: [.product(name: "WillagramsRules", package: "Willagrams")],
            path: "MatchSrc"
        ),
        .testTarget(name: "MatchTests", dependencies: ["Match"], path: "Cases"),
    ]
)
