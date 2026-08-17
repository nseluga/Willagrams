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
        .target(
            name: "Shell",
            dependencies: [.product(name: "WillagramsRules", package: "Willagrams")],
            path: "ShellSrc",
            // The macOS test build has no SwiftUI. Every view file in
            // `Willagrams/Shell` must be listed here, and `SourceGuardrailTests`
            // fails if this list and the files that import SwiftUI disagree.
            exclude: ["ShellRootView.swift"]
        ),
        .testTarget(name: "ShellTests", dependencies: ["Shell"], path: "Cases"),
    ]
)
