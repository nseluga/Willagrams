// swift-tools-version: 6.0
import PackageDescription

// The profile screen's package. Built for macOS with no simulator, so it
// compiles no SwiftUI: `AccountSrc/ProfileView.swift` is excluded below and
// `SourceGuardrailTests` fails if this list and the files that import SwiftUI
// ever disagree.
//
// `name:` on the path dependency is load-bearing: a path dependency's identity
// is otherwise its directory name, so a bare `.package(path:)` resolves to the
// worktree's name — "shell3-auto" here — and the product lookup fails.
let package = Package(
    name: "AccountTests",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "Willagrams", path: "../.."),
    ],
    targets: [
        // The app compiles `Willagrams/Match` and `Willagrams/Online` into one
        // module with everything else, so those files carry no imports of each
        // other; here they are one target for the same reason `Tests/ShellTests`
        // makes them one. Only the four SDK-free `Online` files join — the rest
        // needs the Supabase SDK, and `Tests/OnlineTests` owns those. This is
        // ShellTests' "extra sources" approach rather than OnlineTests' whole
        // `OnlineSrc` directory, because pulling the directory in would drag the
        // SDK into a package that otherwise resolves nothing.
        .target(
            name: "Match",
            dependencies: [
                .product(name: "WillagramsRules", package: "Willagrams"),
            ],
            path: ".",
            sources: [
                "MatchSrc",
                "OnlineSrc/BackendContracts.swift",
                "OnlineSrc/FakeBackend.swift",
                // `FakeBackend` conforms to it, so it has to be here even
                // though the profile screen never declines anything.
                "OnlineSrc/FriendRequestForgetting.swift",
                "OnlineSrc/MatchOutcomeRecorder.swift",
                "OnlineSrc/OnlineMatch.swift",
            ]
        ),
        // `Willagrams/Account`, symlinked whole. `ProfileModel` reaches `Profile`
        // and `BackendClient` through `import Match` here and through no import
        // at all in the app, which is what the `#if canImport(Match)` at the top
        // of it is for.
        //
        // EVERY View file in `Willagrams/Account` must be named here or this
        // package stops building.
        .target(
            name: "Account",
            dependencies: ["Match"],
            path: "AccountSrc",
            exclude: ["ProfileView.swift"]
        ),
        .testTarget(
            name: "AccountTests",
            dependencies: ["Account", "Match"],
            path: "Cases"
        ),
    ]
)
