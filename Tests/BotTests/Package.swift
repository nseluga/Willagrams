// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BotTests",
    platforms: [.iOS(.v17), .macOS(.v14)],
    // `name:` is load-bearing: a path dependency's identity is otherwise its
    // directory name, so a bare `.package(path:)` resolves to "botrun" in a
    // worktree and the product lookup below fails.
    dependencies: [.package(name: "Willagrams", path: "../..")],
    targets: [
        // The app compiles `Willagrams/Match` into the same module as the bot;
        // here it is a separate one, which is what the `#if canImport(Match)`
        // in `LocalMatchLink.swift` exists for. Symlinked, not copied — this
        // lane consumes those files and never edits them.
        .target(
            name: "Match",
            dependencies: [.product(name: "WillagramsRules", package: "Willagrams")],
            path: "MatchSrc"
        ),
        .target(
            name: "Bot",
            dependencies: ["Match", .product(name: "WillagramsRules", package: "Willagrams")],
            path: "BotSrc",
            // The macOS test build has no SwiftUI. Every view file in
            // `Willagrams/Bot` must be listed here — a new one that is not
            // stops this package building. `BotDifficultyView.swift` goes here.
            exclude: ["BotDifficultyView.swift"]
        ),
        .testTarget(name: "BotTests", dependencies: ["Bot", "Match"], path: "Cases"),
    ]
)
