// swift-tools-version: 6.0
import PackageDescription

// One target, two source dirs: the app compiles `Match` and `Online` into a
// single module, so the files carry no `import Match`. Splitting them into two
// SwiftPM targets here would need imports the app does not want.
let package = Package(
    name: "OnlineTests",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(path: "../.."),
        // Pinned exactly to what `Willagrams.xcodeproj` resolves, so the app and
        // this package never compile the same file against two SDK versions.
        .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.55.1"),
    ],
    targets: [
        .target(
            name: "Online",
            dependencies: [
                .product(name: "WillagramsRules", package: "Willagrams"),
                .product(name: "Auth", package: "supabase-swift"),
                .product(name: "PostgREST", package: "supabase-swift"),
                .product(name: "Realtime", package: "supabase-swift"),
            ],
            path: ".",
            sources: ["MatchSrc", "OnlineSrc"]
        ),
        .testTarget(
            name: "OnlineTests",
            dependencies: ["Online", .product(name: "Auth", package: "supabase-swift")],
            path: "Cases"
        ),
    ]
)
