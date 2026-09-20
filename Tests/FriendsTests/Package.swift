// swift-tools-version: 6.0
import PackageDescription

// The friends list's package. Built for macOS with no simulator, so it compiles
// no SwiftUI: `FriendsSrc/FriendsView.swift` is excluded below and
// `SourceGuardrailTests` fails if this list and the files that import SwiftUI
// ever disagree.
//
// Unlike `Tests/AccountTests`, this package pulls the *whole* `OnlineSrc`
// directory and the Supabase SDK with it: the live cases here sign two
// anonymous users in through `SupabaseBackend.signInAnonymously()`, which is the
// only way to prove the `friendships` RLS policies from the outside. That is
// `Tests/OnlineTests`' shape, pin included — the app and this package must never
// compile the same file against two SDK versions.
//
// `name:` on the path dependency is load-bearing: a path dependency's identity
// is otherwise its directory name, so a bare `.package(path:)` resolves to the
// worktree's name and the product lookup fails.
let package = Package(
    name: "FriendsTests",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(name: "Willagrams", path: "../.."),
        .package(url: "https://github.com/supabase/supabase-swift.git", exact: "2.55.1"),
    ],
    targets: [
        // One target, two source dirs, for the reason `Tests/OnlineTests` gives:
        // the app compiles `Match` and `Online` into a single module, so those
        // files carry no `import Match` and two SwiftPM targets would need
        // imports the app does not want.
        //
        // Named `Match`, so `Willagrams/Friends/FriendsModel.swift` reaches
        // `Profile`, `Friendship` and `BackendClient` through the same
        // `#if canImport(Match)` it uses in every other package.
        .target(
            name: "Match",
            dependencies: [
                .product(name: "WillagramsRules", package: "Willagrams"),
                .product(name: "Auth", package: "supabase-swift"),
                .product(name: "PostgREST", package: "supabase-swift"),
                .product(name: "Realtime", package: "supabase-swift"),
            ],
            path: ".",
            sources: ["MatchSrc", "OnlineSrc"]
        ),
        // `Willagrams/Friends`, symlinked whole. EVERY View file in it must be
        // named here or this package stops building.
        .target(
            name: "Friends",
            dependencies: ["Match"],
            path: "FriendsSrc",
            exclude: ["FriendsView.swift"]
        ),
        .testTarget(
            name: "FriendsTests",
            dependencies: [
                "Friends",
                "Match",
                .product(name: "Auth", package: "supabase-swift"),
            ],
            path: "Cases"
        ),
    ]
)
