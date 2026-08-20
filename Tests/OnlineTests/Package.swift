// swift-tools-version: 6.0
import PackageDescription

// One target, two source dirs: the app compiles `Match` and `Online` into a
// single module, so the files carry no `import Match`. Splitting them into two
// SwiftPM targets here would need imports the app does not want.
let package = Package(
    name: "OnlineTests",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [
        .target(
            name: "Online",
            dependencies: [.product(name: "WillagramsRules", package: "Willagrams")],
            path: ".",
            sources: ["MatchSrc", "OnlineSrc"]
        ),
        .testTarget(name: "OnlineTests", dependencies: ["Online"], path: "Cases"),
    ]
)
