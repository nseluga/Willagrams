// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShellTests",
    platforms: [.iOS(.v17), .macOS(.v14)],
    // `name:` is load-bearing: a path dependency's identity is otherwise its
    // directory name, so the bare `.package(path:)` MatchTests uses resolves to
    // "shell-r1" in a worktree and the product lookup below fails.
    dependencies: [.package(name: "Willagrams", path: "../..")],
    targets: [
        // The app compiles `Willagrams/Match` into the same module as the shell;
        // here it is a separate one, which is what the `#if canImport(Match)`
        // in `SoloMatch.swift` exists for. Symlinked, not copied — this lane
        // consumes those files and never edits them.
        .target(
            name: "Match",
            dependencies: [.product(name: "WillagramsRules", package: "Willagrams")],
            path: "MatchSrc"
        ),
        // One file, symlinked in: `Terminology` is the frozen IP fence and the
        // countdown's title comes from it. The rest of `Willagrams/Style` is
        // SwiftUI and cannot build for this target, which is why this is a
        // directory of file symlinks rather than a symlink to the directory.
        .target(name: "Style", path: "StyleSrc"),
        .target(
            name: "Shell",
            dependencies: ["Match", "Style", .product(name: "WillagramsRules", package: "Willagrams")],
            path: "ShellSrc",
            // The macOS test build has no SwiftUI. Every view file in
            // `Willagrams/Shell` must be listed here, and `SourceGuardrailTests`
            // fails if this list and the files that import SwiftUI disagree.
            exclude: ["ShellRootView.swift", "MenuView.swift", "CountdownView.swift"]
        ),
        .testTarget(name: "ShellTests", dependencies: ["Shell", "Match", "Style"], path: "Cases"),
    ]
)
